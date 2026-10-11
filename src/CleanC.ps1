#Requires -Version 5.1
<#
    CleanC - C: drive cleanup tool (GUI)

    Design rule learned the hard way: this tool NEVER deletes anything by itself.
    It scans, classifies every target as Safe / Caution / Keep, shows you the size,
    and only removes what you tick. Big wins come from judgement, not from a script.

    Every target carries a handwritten note in .Note explaining WHY its risk level
    is what it is, so a future you can re-check the reasoning.
#>

# ---------------------------------------------------------------- self-elevate
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    try {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        $exe  = $proc.MainModule.FileName
        if ($exe -like '*powershell.exe' -or $exe -like '*pwsh.exe') {
            $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
            if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argl
            } else { exit }
        } else {
            Start-Process -FilePath $exe -Verb RunAs
        }
    } catch { }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    # compiled by ps2exe: $PSScriptRoot is empty, so take the exe's own folder
    try { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    catch { $env:TEMP }
}
$script:LogFile = Join-Path $script:ScriptDir 'CleanC.log'

# ------------------------------------------------------------------- helpers
function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    # the exe may sit somewhere read-only (a share, a USB stick) - fall back to %TEMP%
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'CleanC.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
    if ($script:LblStatus) { $script:LblStatus.Text = $msg; Pump-UI }
}

function Pump-UI { [System.Windows.Forms.Application]::DoEvents() }

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ('{0} B' -f $bytes)
}

function Get-RiskLabel([string]$risk) {
    switch ($risk) { 'Safe' { '安全' } 'Caution' { '注意' } default { '勿动' } }
}

# Fast enumerator. Get-ChildItem -Recurse is 10-50x slower here and walks into
# reparse points (C:\Documents and Settings -> C:\Users), double counting.
function Get-DirSize([string]$root) {
    $sum = [long]0
    if (-not (Test-Path -LiteralPath $root)) { return 0 }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                try { $sum += ([System.IO.FileInfo]$f).Length } catch { }
            }
        } catch { }
        try {
            foreach ($sd in [System.IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    if (([System.IO.File]::GetAttributes($sd)) -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($sd)
                } catch { }
            }
        } catch { }
    }
    return $sum
}

function Get-RecycleBinSize {
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb = $shell.NameSpace(0xA)
        $sum = [long]0
        foreach ($i in $rb.Items()) { try { $sum += $i.Size } catch { } }
        return $sum
    } catch { return 0 }
}

# --------------------------------------------------------------- target list
# Risk: Safe = green, ticked by default
#       Caution = amber, not ticked
#       Keep = grey, cannot be ticked - shown so you can see WHY it is off limits
function Get-Targets {
    $L = $env:LOCALAPPDATA
    $A = $env:APPDATA
    $U = $env:USERPROFILE
    $t = New-Object System.Collections.ArrayList

    function Add2($label, $risk, $path, $mode, $note, $exclude, $defTick) {
        $null = $t.Add([PSCustomObject]@{
            Label = $label; Risk = $risk; Path = $path; Mode = $mode
            Note = $note; Exclude = $exclude; DefaultTick = $defTick; Size = [long]0
        })
    }

    # ---- SAFE: regenerated automatically, no user data ----
    Add2 '系统临时文件' 'Safe' (Join-Path $L 'Temp') 'EmptyExcept' `
        '系统随时在写。默认排除 claude 子目录 —— 那是 AI 编程助手（Claude Code 等）的任务输出，删掉会丢正在跑的结果。' @('claude') $true
    Add2 '回收站' 'Safe' '' 'RecycleBin' '你主动删过的东西，清空即释放。' @() $true
    Add2 '崩溃转储' 'Safe' (Join-Path $L 'CrashDumps') 'Empty' '程序崩溃时写的 dump，没有诊断价值。' @() $true
    Add2 '缩略图缓存' 'Safe' (Join-Path $L 'Microsoft\Windows\Explorer') 'Empty' '资源管理器缩略图数据库，会自动重建（重建时首次浏览文件夹略慢）。' @() $true
    Add2 'Edge 缓存' 'Safe' (Join-Path $L 'Microsoft\Edge\User Data\Default\Cache') 'Empty' '网页缓存。Edge 运行中会被锁住一部分，关掉 Edge 再清更彻底。' @() $true
    Add2 'Edge 代码缓存' 'Safe' (Join-Path $L 'Microsoft\Edge\User Data\Default\Code Cache') 'Empty' '编译后的 JS，自动重建。' @() $true
    Add2 'Edge GPUCache' 'Safe' (Join-Path $L 'Microsoft\Edge\User Data\Default\GPUCache') 'Empty' 'GPU 着色器缓存，自动重建。' @() $true
    Add2 'Edge ShaderCache' 'Safe' (Join-Path $L 'Microsoft\Edge\User Data\ShaderCache') 'Empty' '自动重建。' @() $true
    Add2 'Chrome 缓存' 'Safe' (Join-Path $L 'Google\Chrome\User Data\Default\Cache') 'Empty' '同上（装了 Chrome 才有）。' @() $true
    Add2 'DirectX 着色器缓存' 'Safe' (Join-Path $L 'D3DSCache') 'Empty' '游戏/3D 程序自动重建。' @() $true
    Add2 'NVIDIA 着色器缓存' 'Safe' (Join-Path $L 'NVIDIA\DXCache') 'Empty' '自动重建。' @() $true
    Add2 'pip 缓存' 'Safe' (Join-Path $L 'pip\cache') 'Empty' 'pip 下载的 wheel 包，重装会重新下。' @() $true
    Add2 'npm 缓存' 'Safe' (Join-Path $L 'npm-cache\_cacache') 'Empty' 'npm 包缓存，npm 自己也能清。' @() $true
    Add2 'Windows 临时文件' 'Safe' 'C:\Windows\Temp' 'Empty' '系统级临时文件（需要管理员，本工具已是）。' @() $true

    # ---- CAUTION: real content, but rebuildable ----
    Add2 'Windows 更新缓存' 'Caution' 'C:\Windows\SoftwareDistribution\Download' 'Service' `
        '已下载的更新包。删除要停 wuauserv，本工具会自动停/起。不清也不影响，更新完会自己回收。' @() $false
    Add2 'Office 加载项缓存' 'Caution' (Join-Path $L 'Microsoft\Office\SolutionPackages') 'Empty' `
        'Office 的共享加载项。删了 Office 会重新下载，首次用相关功能会等。' @() $false
    Add2 'UWP 应用缓存' 'Caution' (Join-Path $L 'Packages') 'UwpCache' `
        'Store 应用的 LocalCache/TempState。安全，但个别应用首次启动会慢一点。' @() $false
    Add2 '腾讯会议更新包' 'Caution' (Join-Path $A 'Tencent\WeMeet\Global\UpdatePackages') 'Empty' `
        '已应用完的更新包，属于遗留文件，删掉不影响使用。' @() $false
    Add2 '腾讯会议日志' 'Caution' (Join-Path $A 'Tencent\WeMeet\Global\Logs') 'Empty' '日志文件。' @() $false

    # ---- KEEP: shown but not deletable, with the reason ----
    Add2 'Codex 插件运行时' 'Keep' (Join-Path $U '.cache\codex-runtimes') 'Whole' `
        '禁止删除。~\.codex\config.toml 把它注册为插件市场源，挂着 pdf/文档/表格/演示等插件。删了插件全废。' @() $false
    Add2 'Codex 运行时' 'Keep' (Join-Path $L 'OpenAI\Codex') 'Whole' `
        '禁止删除。config.toml 里的 MCP server 直接指向这里的 node_repl.exe。' @() $false
    Add2 'Codex 配置与会话' 'Keep' (Join-Path $U '.codex') 'Whole' `
        '禁止删除。这是 agent 本体的配置与状态库（sqlite/sessions/plugins），不是缓存。' @() $false
    Add2 'TRAE agent 沙箱' 'Keep' (Join-Path $A 'TRAE SOLO CN\ModularData\ai-agent\vm') 'Whole' `
        'TRAE 的 AI agent 运行环境（python/node/fonts/app）。可重新下载，但要用 TRAE agent 就得留。' @() $false
    Add2 '百度网盘组件' 'Keep' (Join-Path $A 'baidu\BaiduNetdisk\module') 'Whole' `
        '禁止删除。这个目录就是百度网盘的安装位置，module 里是程序本体。要用就别删。' @() $false
    Add2 'MSI 安装缓存' 'Keep' 'C:\Windows\Installer' 'Whole' `
        '禁止删除。删了之后已装程序的修复/卸载/更新会失败。' @() $false
    Add2 'Defender 定义库' 'Keep' 'C:\ProgramData\Microsoft\Windows\Windows Defender' 'Whole' `
        '禁止删除。杀毒引擎的病毒库，系统自动管理。' @() $false

    return $t
}

function Get-TargetSize([object]$t) {
    switch ($t.Mode) {
        'RecycleBin' { return (Get-RecycleBinSize) }
        'UwpCache' {
            $sum = [long]0
            if (Test-Path -LiteralPath $t.Path) {
                foreach ($p in (Get-ChildItem -LiteralPath $t.Path -Directory -Force -ErrorAction SilentlyContinue)) {
                    foreach ($sub in @('LocalCache', 'TempState')) {
                        $d = Join-Path $p.FullName $sub
                        if (Test-Path -LiteralPath $d) { $sum += (Get-DirSize $d) }
                    }
                }
            }
            return $sum
        }
        default { return (Get-DirSize $t.Path) }
    }
}

# ------------------------------------------------------------------ cleaning
function Invoke-CleanOne([object]$t) {
    $freed = [long]0
    switch ($t.Mode) {
        'RecycleBin' {
            $before = Get-RecycleBinSize
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
            $freed = $before - (Get-RecycleBinSize)
        }
        'Service' {
            if (Test-Path -LiteralPath $t.Path) {
                $before = Get-DirSize $t.Path
                try { Stop-Service wuauserv -Force -ErrorAction Stop } catch { }
                Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                try { Start-Service wuauserv -ErrorAction Stop } catch { }
                $freed = $before - (Get-DirSize $t.Path)
            }
        }
        'UwpCache' {
            if (Test-Path -LiteralPath $t.Path) {
                foreach ($p in (Get-ChildItem -LiteralPath $t.Path -Directory -Force -ErrorAction SilentlyContinue)) {
                    foreach ($sub in @('LocalCache', 'TempState')) {
                        $d = Join-Path $p.FullName $sub
                        if (-not (Test-Path -LiteralPath $d)) { continue }
                        $before = Get-DirSize $d
                        Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        $freed += $before - (Get-DirSize $d)
                    }
                }
            }
        }
        'Whole' {
            if (Test-Path -LiteralPath $t.Path) {
                $before = Get-DirSize $t.Path
                Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
                $freed = $before - (Get-DirSize $t.Path)
            }
        }
        default {
            if (Test-Path -LiteralPath $t.Path) {
                $before = Get-DirSize $t.Path
                foreach ($k in (Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue)) {
                    if ($t.Exclude -and ($t.Exclude -contains $k.Name)) { continue }
                    Remove-Item -LiteralPath $k.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                $freed = $before - (Get-DirSize $t.Path)
            }
        }
    }
    return $freed
}

# Rescan the given targets and rebuild the list so it reflects reality.
function Update-Rows([object[]]$rescan) {
    $script:Loading = $true
    $lv.BeginUpdate()
    if ($rescan) { foreach ($t in $rescan) { $t.Size = Get-TargetSize $t } }
    $lv.Items.Clear()
    $script:Rows.Clear()
    foreach ($t in $script:Targets) { Add-Row $t }
    $lv.EndUpdate()
    $script:Loading = $false
    Update-DriveBar
    Update-SelSummary
}

# The one path that actually deletes. Both the "clean selected" and
# "one-click clean safe" buttons funnel through here, so the confirmation
# dialog and the before/after accounting can never be bypassed.
function Invoke-CleanSelected([object[]]$picked) {
    if (-not $picked -or @($picked).Count -eq 0) { return }
    $picked = @($picked)
    $sum = [long]0
    foreach ($p in $picked) { $sum += $p.Target.Size }

    $msg = "将清理 {0} 项，预计释放约 {1}。`n`n" -f $picked.Count, (Format-Size $sum)
    $msg += (($picked | ForEach-Object { '  · {0}   ({1})' -f $_.Target.Label, (Format-Size $_.Target.Size) }) -join "`n")
    $msg += "`n`n继续吗？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认清理', 'YesNo', 'Question') -ne 'Yes') {
        Write-Log '用户取消了清理'
        return
    }

    $btnScan.Enabled = $false
    $btnClean.Enabled = $false
    $btnSafeClean.Enabled = $false
    $script:Progress.Minimum = 0
    $script:Progress.Maximum = $picked.Count
    $script:Progress.Value = 0

    $cBefore = (Get-PSDrive C).Free
    $i = 0
    foreach ($p in $picked) {
        $i++
        $script:LblStatus.Text = ('正在清理 [{0}/{1}]  {2} ...' -f $i, $picked.Count, $p.Target.Label)
        $script:Progress.Value = $i
        Pump-UI
        $freed = Invoke-CleanOne $p.Target
        Write-Log ('清理 {0}：释放 {1}' -f $p.Target.Label, (Format-Size $freed))
    }
    $cAfter = (Get-PSDrive C).Free
    $net = $cAfter - $cBefore

    Update-Rows @($picked | ForEach-Object { $_.Target })

    $script:Progress.Value = 0
    $btnScan.Enabled = $true
    $btnSafeClean.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show(
        ("清理完成。`n`n删除的文件合计 : {0}`nC: 净变化      : {1} MB`nC: 当前可用    : {2:N2} GB`n`n" +
         "两个数不一样是正常的：删除期间系统还在写盘，会吃掉一部分差额。") -f `
            (Format-Size $sum), [math]::Round($net / 1MB, 0), ($cAfter / 1GB),
        '完成', 'OK', 'Information') | Out-Null

    Write-Log ('本轮净释放 {0:N0} MB，C: 可用 {1:N2} GB' -f ($net / 1MB), ($cAfter / 1GB))
}

# ------------------------------------------------------------------ export
function Export-ScanCsv {
    if ($script:Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('还没有扫描结果，先点「扫描」。', '导出 CSV', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '导出扫描结果'
    $dlg.Filter = 'CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*'
    $dlg.FileName = 'CleanC-scan-{0}.csv' -f (Get-Date -Format 'yyyy-MM-dd-HHmm')
    $dlg.InitialDirectory = $script:ScriptDir
    $dlg.OverwritePrompt = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    $target = $dlg.FileName
    $dlg.Dispose()

    $rows = foreach ($r in $script:Rows) {
        [PSCustomObject]@{
            '项目'     = $r.Target.Label
            '风险'     = Get-RiskLabel $r.Target.Risk
            '大小(MB)' = [math]::Round($r.Target.Size / 1MB, 1)
            '字节'     = $r.Target.Size
            '已选中'   = $(if ($r.Item.Checked) { '是' } else { '否' })
            '路径'     = $r.Target.Path
            '说明'     = $r.Target.Note
        }
    }

    # Export-Csv -Encoding UTF8 writes a BOM under PS 5.1, so Excel reads the
    # Chinese headers correctly instead of showing mojibake.
    try {
        @($rows) | Export-Csv -LiteralPath $target -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            ('写入失败：' + $_.Exception.Message), '导出 CSV', 'OK', 'Error') | Out-Null
        return
    }

    $d = Get-PSDrive C
    $total = $d.Used + $d.Free
    Write-Log ('已导出 {0} 行到 {1}' -f @($rows).Count, $target)
    [System.Windows.Forms.MessageBox]::Show(
        ("已导出 {0} 行。`n`n文件 : {1}`n`n扫描时刻的 C: 可用 : {2:N2} GB / 总 {3:N1} GB" -f `
            @($rows).Count, $target, ($d.Free / 1GB), ($total / 1GB)),
        '导出 CSV', 'OK', 'Information') | Out-Null
}

# ------------------------------------------------------------------ the form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'C 盘清理工具'
$form.Size = New-Object System.Drawing.Size(960, 720)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(820, 600)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)

# --- header: drive usage bar
$pnlHead = New-Object System.Windows.Forms.Panel
$pnlHead.Location = New-Object System.Drawing.Point(14, 12)
$pnlHead.Size = New-Object System.Drawing.Size(920, 86)
$pnlHead.Anchor = 'Top,Left,Right'
$form.Controls.Add($pnlHead)

$lblDrive = New-Object System.Windows.Forms.Label
$lblDrive.Text = 'C:'
$lblDrive.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$lblDrive.Location = New-Object System.Drawing.Point(2, 4)
$lblDrive.Size = New-Object System.Drawing.Size(48, 34)
$lblDrive.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$pnlHead.Controls.Add($lblDrive)

$barBack = New-Object System.Windows.Forms.Panel
$barBack.Location = New-Object System.Drawing.Point(56, 12)
$barBack.Size = New-Object System.Drawing.Size(600, 22)
$barBack.BackColor = [System.Drawing.Color]::FromArgb(228, 229, 235)
$pnlHead.Controls.Add($barBack)

$barFill = New-Object System.Windows.Forms.Panel
$barFill.Location = New-Object System.Drawing.Point(0, 0)
$barFill.Size = New-Object System.Drawing.Size(10, 22)
$barFill.BackColor = [System.Drawing.Color]::FromArgb(90, 170, 90)
$barBack.Controls.Add($barFill)

$lblBar = New-Object System.Windows.Forms.Label
$lblBar.Text = ''
$lblBar.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$lblBar.Location = New-Object System.Drawing.Point(664, 13)
$lblBar.Size = New-Object System.Drawing.Size(250, 20)
$lblBar.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$pnlHead.Controls.Add($lblBar)

$lblDriveDetail = New-Object System.Windows.Forms.Label
$lblDriveDetail.Text = ''
$lblDriveDetail.Location = New-Object System.Drawing.Point(58, 42)
$lblDriveDetail.Size = New-Object System.Drawing.Size(850, 20)
$lblDriveDetail.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$pnlHead.Controls.Add($lblDriveDetail)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '绿色 = 可安全清理   橙色 = 有内容但可重建   灰色 = 禁止删除（列出原因供你核对）'
$lblHint.Location = New-Object System.Drawing.Point(58, 64)
$lblHint.Size = New-Object System.Drawing.Size(850, 20)
$lblHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150)
$pnlHead.Controls.Add($lblHint)

# --- toolbar
function New-Btn($text, $x, $w, $accent) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 106)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    switch ($accent) {
        'blue' {
            $b.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
        }
        'green' {
            $b.BackColor = [System.Drawing.Color]::FromArgb(40, 140, 70)
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(40, 140, 70)
        }
        default {
            $b.BackColor = [System.Drawing.Color]::White
            $b.ForeColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
        }
    }
    $b.Anchor = 'Top,Left'
    return $b
}

$btnScan = New-Btn '扫描' 14 88 'blue'
$form.Controls.Add($btnScan)

$btnSafeClean = New-Btn '一键清理安全项' 110 140 'green'
$btnSafeClean.Enabled = $false
$form.Controls.Add($btnSafeClean)

$btnClean = New-Btn '清理选中项' 258 116 $null
$btnClean.Enabled = $false
$form.Controls.Add($btnClean)

$btnSafeAll = New-Btn '只选安全项' 382 100 $null
$form.Controls.Add($btnSafeAll)

$btnNone = New-Btn '全不选' 490 76 $null
$form.Controls.Add($btnNone)

$btnExport = New-Btn '导出 CSV' 574 96 $null
$form.Controls.Add($btnExport)

$chkShowKeep = New-Object System.Windows.Forms.CheckBox
$chkShowKeep.Text = '显示禁止删除项'
$chkShowKeep.Location = New-Object System.Drawing.Point(766, 112)
$chkShowKeep.Size = New-Object System.Drawing.Size(160, 22)
$chkShowKeep.Checked = $true
$chkShowKeep.Anchor = 'Top,Right'
$form.Controls.Add($chkShowKeep)

# --- list
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(14, 146)
$lv.Size = New-Object System.Drawing.Size(920, 420)
$lv.Anchor = 'Top,Bottom,Left,Right'
$lv.View = 'Details'
$lv.CheckBoxes = $true
$lv.FullRowSelect = $true
$lv.GridLines = $false
$lv.HeaderStyle = 'Nonclickable'
$lv.BorderStyle = 'FixedSingle'
$lv.BackColor = [System.Drawing.Color]::White
[void]$lv.Columns.Add('项目', 250)
[void]$lv.Columns.Add('风险', 70)
[void]$lv.Columns.Add('大小', 100)
[void]$lv.Columns.Add('路径 / 说明', 480)
$form.Controls.Add($lv)

# --- bottom
$lblSel = New-Object System.Windows.Forms.Label
$lblSel.Text = '尚未扫描'
$lblSel.Location = New-Object System.Drawing.Point(16, 578)
$lblSel.Size = New-Object System.Drawing.Size(560, 22)
$lblSel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$lblSel.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$lblSel.Anchor = 'Bottom,Left'
$form.Controls.Add($lblSel)

$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Location = New-Object System.Drawing.Point(586, 578)
$script:Progress.Size = New-Object System.Drawing.Size(348, 20)
$script:Progress.Anchor = 'Bottom,Right'
$form.Controls.Add($script:Progress)

$script:LblStatus = New-Object System.Windows.Forms.Label
$script:LblStatus.Text = '就绪。点「扫描」开始。'
$script:LblStatus.Location = New-Object System.Drawing.Point(16, 606)
$script:LblStatus.Size = New-Object System.Drawing.Size(920, 22)
$script:LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$script:LblStatus.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($script:LblStatus)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "日志：$script:LogFile"
$lblLog.Location = New-Object System.Drawing.Point(16, 632)
$lblLog.Size = New-Object System.Drawing.Size(920, 20)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 170)
$lblLog.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($lblLog)

# ------------------------------------------------------------------ state
$script:Rows = New-Object System.Collections.ArrayList   # item -> target map
$script:Loading = $false

function Update-DriveBar {
    $d = Get-PSDrive C
    $total = $d.Used + $d.Free
    $pct = if ($total -gt 0) { [math]::Round(100.0 * $d.Used / $total, 0) } else { 0 }
    $lblBar.Text = '{0}% 已用' -f $pct
    $fillW = [int]($barBack.Width * $d.Used / $total)
    if ($fillW -lt 2) { $fillW = 2 }
    if ($fillW -gt $barBack.Width) { $fillW = $barBack.Width }
    $barFill.Size = New-Object System.Drawing.Size($fillW, 22)
    if ($pct -ge 90) { $barFill.BackColor = [System.Drawing.Color]::FromArgb(212, 70, 70) }
    elseif ($pct -ge 75) { $barFill.BackColor = [System.Drawing.Color]::FromArgb(226, 150, 50) }
    else { $barFill.BackColor = [System.Drawing.Color]::FromArgb(90, 170, 90) }
    $lblDriveDetail.Text = '总计 {0:N1} GB    已用 {1:N1} GB    可用 {2:N2} GB' -f `
        ($total / 1GB), ($d.Used / 1GB), ($d.Free / 1GB)
}

function Update-SelSummary {
    if ($script:Loading) { return }
    $n = 0; $sum = [long]0
    foreach ($r in $script:Rows) {
        if ($r.Item.Checked) { $n++; $sum += $r.Target.Size }
    }
    if ($n -eq 0) {
        $lblSel.Text = '未选中任何项'
        $btnClean.Enabled = $false
    } else {
        $lblSel.Text = '已选 {0} 项 · 预计释放约 {1}' -f $n, (Format-Size $sum)
        $btnClean.Enabled = $true
    }
}

function Add-Row([object]$t) {
    if ($t.Risk -eq 'Keep' -and -not $chkShowKeep.Checked) { return }
    $it = New-Object System.Windows.Forms.ListViewItem($t.Label)
    [void]$it.SubItems.Add((Get-RiskLabel $t.Risk))
    [void]$it.SubItems.Add($(if ($t.Size -gt 0) { Format-Size $t.Size } else { '空' }))
    [void]$it.SubItems.Add($t.Path + '   — ' + $t.Note)
    switch ($t.Risk) {
        'Safe' { $it.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50) }
        'Caution' { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 120, 20) }
        default { $it.ForeColor = [System.Drawing.Color]::FromArgb(165, 165, 175) }
    }
    $it.Tag = $t
    $it.Checked = [bool]$t.DefaultTick
    [void]$lv.Items.Add($it)
    $null = $script:Rows.Add([PSCustomObject]@{ Item = $it; Target = $t })
}

# ------------------------------------------------------------------ events
$lv.Add_ItemCheck({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $t = $s.Items[$e.Index].Tag
    if ($t -and $t.Risk -eq 'Keep' -and $e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
        $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked
        $script:LblStatus.Text = ('「{0}」是禁止删除项：{1}' -f $t.Label, $t.Note)
    }
})

$lv.Add_ItemChecked({ Update-SelSummary })

$chkShowKeep.Add_CheckedChanged({
    if ($script:Rows.Count -eq 0) { return }
    $script:Loading = $true
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $script:Rows.Clear()
    foreach ($t in $script:Targets) { Add-Row $t }
    $lv.EndUpdate()
    $script:Loading = $false
    Update-SelSummary
})

$btnSafeAll.Add_Click({
    $script:Loading = $true
    foreach ($r in $script:Rows) {
        if ($r.Target.Risk -eq 'Safe') { $r.Item.Checked = $true }
    }
    $script:Loading = $false
    Update-SelSummary
})

$btnNone.Add_Click({
    $script:Loading = $true
    foreach ($r in $script:Rows) { $r.Item.Checked = $false }
    $script:Loading = $false
    Update-SelSummary
})

$btnExport.Add_Click({ Export-ScanCsv })

$btnScan.Add_Click({
    $btnScan.Enabled = $false
    $btnClean.Enabled = $false
    $btnSafeClean.Enabled = $false
    $script:Loading = $true
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $script:Rows.Clear()
    $script:Targets = Get-Targets
    $lv.EndUpdate()
    $script:Loading = $false

    $script:Progress.Minimum = 0
    $script:Progress.Maximum = $script:Targets.Count
    $script:Progress.Value = 0

    $i = 0
    $grand = [long]0
    foreach ($t in $script:Targets) {
        $i++
        $script:LblStatus.Text = ('正在统计 [{0}/{1}]  {2} ...' -f $i, $script:Targets.Count, $t.Label)
        $script:Progress.Value = $i
        Pump-UI
        if ($t.Mode -ne 'RecycleBin') {
            if (Test-Path -LiteralPath $t.Path) { $t.Size = Get-TargetSize $t }
        } else {
            $t.Size = Get-RecycleBinSize
        }
        if ($t.Risk -ne 'Keep' -or $chkShowKeep.Checked) { $grand += $t.Size }
    }

    $script:Loading = $true
    $lv.BeginUpdate()
    foreach ($t in $script:Targets) { Add-Row $t }
    $lv.EndUpdate()
    $script:Loading = $false

    Update-DriveBar
    Update-SelSummary
    $script:Progress.Value = 0
    $btnScan.Enabled = $true
    $btnSafeClean.Enabled = $true
    Write-Log ('扫描完成，共 {0} 项，可清理项合计 {1}' -f $script:Targets.Count, (Format-Size $grand))
})

$btnClean.Add_Click({
    $picked = @($script:Rows | Where-Object { $_.Item.Checked -and $_.Target.Risk -ne 'Keep' })
    Invoke-CleanSelected $picked
})

# One-click path: scan if needed, tick every Safe row, then hand it to the same
# confirmation + accounting routine as the manual button. The confirmation
# dialog still lists exactly what is about to be deleted, so this is a
# convenience, not a bypass.
$btnSafeClean.Add_Click({
    if ($script:Rows.Count -eq 0) {
        $script:LblStatus.Text = '尚未扫描，先自动扫描一次...'
        Pump-UI
        $btnScan.PerformClick()
    }
    $safe = @($script:Rows | Where-Object { $_.Target.Risk -eq 'Safe' -and $_.Target.Size -gt 0 })
    if ($safe.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            '没有可清理的安全项（可能已经清过了）。', '一键清理安全项', 'OK', 'Information') | Out-Null
        return
    }
    $script:Loading = $true
    foreach ($s in $safe) { $s.Item.Checked = $true }
    $script:Loading = $false
    Update-SelSummary
    Invoke-CleanSelected $safe
})

$form.Add_Shown({
    Write-Log 'CleanC 启动'
    Update-DriveBar
    $btnScan.PerformClick()
})

[void]$form.ShowDialog()
