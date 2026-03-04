<#
.SYNOPSIS
    Displays the WAU update deadline prompt dialog to the logged-in user.

.DESCRIPTION
    Runs as SYSTEM in the logged-in user's desktop session via ServiceUI.exe.
    Reads pending-updates.json written by the main WAU task and presents a WPF
    dialog listing apps with pending deadlines.

    User actions:
        "Update Now"     -- fires Winget-AutoUpdate-UpdateNow task, then exits
        "Remind Me"      -- writes NextPromptTime to HKLM, then exits
        Window close (X) -- treated as Remind
        Timeout (5 min)  -- treated as Remind

    Must be launched with PowerShell -Sta flag (STA apartment model required for WPF).

.NOTES
    Scheduled task:  Winget-AutoUpdate-UpdatePrompt
    Run as:          SYSTEM (S-1-5-18), RunLevel Highest
    Launch command:  ServiceUI.exe -process:explorer.exe conhost.exe --headless
                         powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta
                         -File WAU-UpdatePrompt.ps1
    Trigger:         On demand (started by Start-UpdatePromptTask.ps1)
    Instances:       IgnoreNew
#>

#Requires -Version 5.1

#region ASSEMBLIES
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
#endregion ASSEMBLIES

#region ROW DATA CLASS
# A proper CLR class is required for reliable WPF data binding.
# PSCustomObject NoteProperties are not guaranteed to be discoverable
# by WPF's PropertyDescriptor mechanism used by DisplayMemberBinding
# and DataTrigger value comparison.
Add-Type -TypeDefinition @'
public class WauAppRow {
    public string Name                 { get; set; }
    public string AvailableVersion     { get; set; }
    public string DeadlineDisplay      { get; set; }
    public string DaysRemainingDisplay { get; set; }
    public int    DaysRemainingValue   { get; set; }
    public bool   IsUrgent             { get; set; }
}
'@
#endregion ROW DATA CLASS

#region READ PENDING UPDATES
$JsonPath = [System.IO.Path]::Combine($PSScriptRoot, 'config', 'pending-updates.json')

if (-not (Test-Path $JsonPath)) {
    Exit 0
}

try {
    $pendingData = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Exit 1
}

if (-not $pendingData.Apps -or @($pendingData.Apps).Count -eq 0) {
    Exit 0
}

$reminderDays = 2
if ($pendingData.Config -and $null -ne $pendingData.Config.ReminderIntervalDays) {
    $reminderDays = [int]$pendingData.Config.ReminderIntervalDays
}
$companyName = ''
if ($pendingData.Config -and $pendingData.Config.CompanyName) {
    $companyName = $pendingData.Config.CompanyName
}
#endregion READ PENDING UPDATES

#region BUILD ROW OBJECTS
$today   = (Get-Date).Date
$appRows = [System.Collections.Generic.List[WauAppRow]]::new()

foreach ($app in @($pendingData.Apps)) {
    $deadline = $null
    try { $deadline = [DateTime]::Parse($app.Deadline) } catch { continue }

    $daysLeft = ($deadline - $today).Days

    $row = [WauAppRow]::new()
    $row.Name                 = $app.Name
    $row.AvailableVersion     = $app.AvailableVersion
    $row.DeadlineDisplay      = $deadline.ToString('MMM d, yyyy')
    $row.DaysRemainingDisplay = switch ($daysLeft) {
        0       { 'Today' }
        1       { '1 day' }
        default { "$daysLeft days" }
    }
    $row.DaysRemainingValue   = $daysLeft
    $row.IsUrgent             = ($daysLeft -le 3)

    $appRows.Add($row)
}

# Sort ascending so most urgent apps appear at the top
$sortedRows = @($appRows | Sort-Object DaysRemainingValue)
#endregion BUILD ROW OBJECTS

#region XAML
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Software Update Required"
    Width="660"
    SizeToContent="Height"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Topmost="True"
    Background="#F3F3F3">

    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0"
                   Name="HeaderText"
                   TextWrapping="Wrap"
                   FontSize="13"
                   FontWeight="SemiBold"
                   Margin="0,0,0,14"/>

        <!-- App list -->
        <ListView Grid.Row="1"
                  Name="AppList"
                  MaxHeight="280"
                  Margin="0,0,0,12"
                  BorderBrush="#CCCCCC"
                  BorderThickness="1"
                  Background="White"
                  IsHitTestVisible="False"
                  ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="Application"
                                    Width="200"
                                    DisplayMemberBinding="{Binding Name}"/>
                    <GridViewColumn Header="Available Version"
                                    Width="130"
                                    DisplayMemberBinding="{Binding AvailableVersion}"/>
                    <GridViewColumn Header="Required By"
                                    Width="100"
                                    DisplayMemberBinding="{Binding DeadlineDisplay}"/>
                    <GridViewColumn Header="Days Remaining"
                                    Width="110"
                                    DisplayMemberBinding="{Binding DaysRemainingDisplay}"/>
                </GridView>
            </ListView.View>
            <ListView.ItemContainerStyle>
                <Style TargetType="ListViewItem">
                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                    <Style.Triggers>
                        <DataTrigger Binding="{Binding IsUrgent}" Value="True">
                            <Setter Property="Background" Value="#FFF3CD"/>
                            <Setter Property="BorderBrush" Value="#FFE69C"/>
                        </DataTrigger>
                    </Style.Triggers>
                </Style>
            </ListView.ItemContainerStyle>
        </ListView>

        <!-- Footer -->
        <TextBlock Grid.Row="2"
                   Text="Updates will run in the background and restart affected applications if necessary."
                   TextWrapping="Wrap"
                   FontSize="11"
                   Foreground="#666666"
                   Margin="0,0,0,16"/>

        <!-- Countdown + action buttons -->
        <DockPanel Grid.Row="3">
            <TextBlock Name="CountdownText"
                       DockPanel.Dock="Left"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#888888"
                       Text=""/>
            <StackPanel DockPanel.Dock="Right"
                        Orientation="Horizontal"
                        HorizontalAlignment="Right">
                <Button Name="RemindButton"
                        Width="170"
                        Height="30"
                        Margin="0,0,10,0"
                        FontSize="12"/>
                <Button Name="UpdateNowButton"
                        Content="Update Now"
                        Width="110"
                        Height="30"
                        FontSize="12"
                        FontWeight="SemiBold"
                        IsDefault="True"/>
            </StackPanel>
        </DockPanel>

    </Grid>
</Window>
'@
#endregion XAML

#region WINDOW SETUP
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$appListCtrl  = $window.FindName('AppList')
$remindBtn    = $window.FindName('RemindButton')
$updateNowBtn = $window.FindName('UpdateNowButton')
$countdownLbl = $window.FindName('CountdownText')
$headerTxt    = $window.FindName('HeaderText')

# Set header text with company name if configured
if ($companyName) {
    $headerTxt.Text = "$companyName requires the following updates to be installed."
}
else {
    $headerTxt.Text = "Your organization requires the following updates to be installed."
}

# Set window icon from WAU's info.png if available
$iconPath = Join-Path $PSScriptRoot 'icons\info.png'
if (Test-Path $iconPath) {
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = New-Object System.Uri($iconPath, [System.UriKind]::Absolute)
    $bitmap.EndInit()
    $window.Icon = $bitmap
}

# Set button label with configured interval
$remindBtn.Content = "Remind Me in $reminderDays Day$(if ($reminderDays -ne 1) { 's' })"

# Populate the ListView
$appListCtrl.ItemsSource = $sortedRows
#endregion WINDOW SETUP

#region INTERACTION LOGIC
# Tracks the user's chosen action. Defaults to Remind so that
# window-close (X) and timeout both result in snooze behaviour.
$script:Action = 'Remind'

# 5-minute countdown -- treated as Remind on expiry
$script:SecondsRemaining = 300

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    $script:SecondsRemaining--

    if ($script:SecondsRemaining -le 0) {
        $timer.Stop()
        $script:Action = 'Remind'
        $window.Close()
    }
    else {
        $mins = [Math]::Floor($script:SecondsRemaining / 60)
        $secs = $script:SecondsRemaining % 60
        $countdownLbl.Text = "Auto-dismissing in $($mins):$($secs.ToString('D2'))"
    }
})

$updateNowBtn.Add_Click({
    $timer.Stop()
    $script:Action = 'UpdateNow'
    $window.Close()
})

$remindBtn.Add_Click({
    $timer.Stop()
    $script:Action = 'Remind'
    $window.Close()
})

# Closing via X button -- timer already stopped by button handlers if applicable,
# but stop it here too in case the user closes the window directly.
$window.Add_Closing({
    $timer.Stop()
})

$timer.Start()
$window.ShowDialog() | Out-Null
#endregion INTERACTION LOGIC

#region ACT ON CHOICE
if ($script:Action -eq 'UpdateNow') {
    $updateTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UpdateNow' -ErrorAction SilentlyContinue
    if ($updateTask) {
        $updateTask | Start-ScheduledTask
    }
}
else {
    # Snooze -- record when the next prompt is allowed so the main
    # SYSTEM task skips the prompt until this time has passed.
    $nextPromptTime = (Get-Date).AddDays($reminderDays).ToString('o')
    $WAURegPath     = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
    try {
        Set-ItemProperty -Path $WAURegPath -Name 'NextPromptTime' -Value $nextPromptTime
    }
    catch {
        # Non-fatal -- worst case WAU prompts again on next run
    }
}
#endregion ACT ON CHOICE
