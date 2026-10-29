param(
    [string] $ApiBaseUrl = 'https://zbin123xgmailc-001-site1.ktempurl.com'
)

$ErrorActionPreference = 'Stop'
$parsedUrl = [Uri]::new($ApiBaseUrl)
if ($parsedUrl.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($parsedUrl.Host)) {
    throw 'API_BASE_URL must be a public HTTPS URL.'
}

flutter build apk --release "--dart-define=API_BASE_URL=$($parsedUrl.AbsoluteUri.TrimEnd('/'))"
if ($LASTEXITCODE -ne 0) {
    throw "Flutter release build failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk\app-release.apk') |
    Select-Object FullName, Length, LastWriteTime
