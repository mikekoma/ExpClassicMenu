<#
  配布用 zip を作る

  使い方:
    powershell -ExecutionPolicy Bypass -File make-release.ps1 -Version ver002

  手順:
    1. 作業ツリーに未コミットの変更がないことを確認する
       (タグ -Version が既にあれば、HEAD がそのタグを指していることも確認する)
    2. Win64 / Release をビルドする(ビルドで書き換わる .res は元に戻す)
    3. HEAD の README.md・LICENSE・docs/ と exe を集め、zip にする
       (zip 内のパス区切りは / にする。Compress-Archive は \ になるので使わない)
    4. README が参照する docs/ の画像がすべて入っているか確認する
    5. zip の SHA-256 を表示する

  出力: dist\ExpClassicMenu-<Version>.zip
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^ver\d{3}$')]
  [string]$Version,

  # RAD Studio の bin フォルダ(rsvars.bat がある場所)
  [string]$BdsBin = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin'
)

$ErrorActionPreference = 'Stop'
$AppName = 'ExpClassicMenu'
$Root = $PSScriptRoot
Set-Location $Root

function Invoke-Git {
  $out = & git @args
  if ($LASTEXITCODE -ne 0) { throw "git $args が失敗しました" }
  $out
}

# ---------------------------------------------------------------- 1. 事前確認
$dirty = Invoke-Git status --porcelain
if ($dirty) { throw "未コミットの変更があります。コミットしてから実行してください。`n$($dirty -join "`n")" }

$head = Invoke-Git rev-parse HEAD
& git rev-parse -q --verify "refs/tags/$Version" *> $null
if ($LASTEXITCODE -eq 0) {
  $tagCommit = Invoke-Git rev-parse "$Version^{commit}"
  if ($tagCommit -ne $head) { throw "タグ $Version が HEAD を指していません。git checkout $Version してから実行してください。" }
}

$rsvars = Join-Path $BdsBin 'rsvars.bat'
if (-not (Test-Path $rsvars)) { throw "rsvars.bat が見つかりません: $rsvars" }

# ---------------------------------------------------------------- 2. ビルド
$dist = Join-Path $Root 'dist'
$work = Join-Path $dist "work-$Version"
if (Test-Path $work) { Remove-Item $work -Recurse -Force -Confirm:$false }
$binDir = Join-Path $work 'bin'
$dcuDir = Join-Path $work 'dcu'
New-Item -ItemType Directory -Force $binDir, $dcuDir | Out-Null

Write-Host "ビルド中 (Win64 / Release) ..."
$cmd = "`"$rsvars`" && msbuild `"$AppName.dproj`" /t:Rebuild /p:Config=Release /p:Platform=Win64 " +
       "/p:DCC_ExeOutput=`"$binDir`" /p:DCC_DcuOutput=`"$dcuDir`" /v:minimal /nologo"
cmd /c $cmd
$buildExit = $LASTEXITCODE
# ビルドで .res が書き換わるので元に戻す
Invoke-Git checkout -- "$AppName.res" | Out-Null
if ($buildExit -ne 0) { throw "ビルドに失敗しました (exit $buildExit)" }

$exe = Join-Path $binDir "$AppName.exe"
if (-not (Test-Path $exe)) { throw "exe ができていません: $exe" }

# ---------------------------------------------------------------- 3. 同梱ファイルを集める
$pkg = Join-Path $work 'pkg'
New-Item -ItemType Directory -Force $pkg | Out-Null
Copy-Item $exe $pkg
foreach ($f in Invoke-Git ls-files -- README.md LICENSE docs) {
  $dst = Join-Path $pkg $f
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item (Join-Path $Root $f) $dst
}

# ---------------------------------------------------------------- 4. 画像の確認
$readme = Get-Content (Join-Path $pkg 'README.md') -Raw -Encoding UTF8
$missing = [regex]::Matches($readme, '\]\((docs/[^)\s]+)\)') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
  Where-Object { -not (Test-Path (Join-Path $pkg $_)) }
if ($missing) { throw "README が参照するファイルが同梱されていません: $($missing -join ', ')" }

# ---------------------------------------------------------------- zip 作成
$zipPath = Join-Path $dist "$AppName-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force -Confirm:$false }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  Get-ChildItem $pkg -Recurse -File | Sort-Object FullName | ForEach-Object {
    $name = $_.FullName.Substring($pkg.Length + 1).Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $_.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
}
finally {
  $zip.Dispose()
}

# ---------------------------------------------------------------- 5. 結果表示
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  Write-Host ''
  Write-Host "作成しました: $zipPath"
  $check.Entries | ForEach-Object { Write-Host ("  {0,-28} {1,10:N0}" -f $_.FullName, $_.Length) }
}
finally {
  $check.Dispose()
}
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
Write-Host ''
Write-Host "SHA-256: $hash"
Write-Host ''
Write-Host "GitHub に公開する例:"
Write-Host "  git tag $Version; git push origin $Version"
Write-Host "  gh release create $Version `"$zipPath`" --title $Version --notes-file <リリースノート>"
