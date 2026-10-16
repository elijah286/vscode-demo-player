param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath,
    [string]$OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'VSCode-Demo-Player\excerpt.native-chat.json'),
    [ValidateRange(1, 100)]
    [int]$RequestCount = 1
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SessionPath).Path
$destination = [System.IO.Path]::GetFullPath($OutputPath)
if ($source -eq $destination) {
    throw 'The export must not overwrite the original session.'
}
if (Test-Path -LiteralPath $destination) {
    throw 'The destination already exists. Choose a new output path.'
}

$reader = [System.IO.File]::OpenText($source)
try {
    $line = $reader.ReadLine()
} finally {
    $reader.Dispose()
}
if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'The native session is empty.'
}
$record = ConvertFrom-Json -InputObject $line
if ($record.kind -ne 0 -or $null -eq $record.v.requests) {
    throw 'Expected a complete native snapshot as the first JSONL record.'
}
$snapshot = $record.v
$available = @($snapshot.requests)
if ($RequestCount -gt $available.Count) {
    throw "Only $($available.Count) requests are available in the first snapshot."
}
$requests = @($available | Select-Object -First $RequestCount)
foreach ($request in $requests) {
    if ($null -eq $request.result -or $null -eq $request.response -or $null -eq $request.message) {
        throw 'The selected excerpt contains an incomplete request.'
    }
}

$export = [ordered]@{
    initialLocation = $snapshot.initialLocation
    requests = $requests
    responderUsername = $snapshot.responderUsername
}
$json = ConvertTo-Json -InputObject $export -Depth 100 -WarningAction Stop
$roundTrip = ConvertFrom-Json -InputObject $json
$before = ConvertTo-Json -InputObject $requests -Depth 100 -Compress -WarningAction Stop
$after = ConvertTo-Json -InputObject @($roundTrip.requests) -Depth 100 -Compress -WarningAction Stop
if ($before -cne $after) {
    throw 'Serialization changed a recorded request. No export was written.'
}

$directory = [System.IO.Path]::GetDirectoryName($destination)
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$stream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
$writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
try {
    $writer.Write($json)
} finally {
    $writer.Dispose()
}

$responseParts = 0
foreach ($request in $requests) {
    $responseParts += @($request.response).Count
}
[pscustomobject]@{
    OutputPath = $destination
    Requests = $requests.Count
    RecordedResponseParts = $responseParts
    RequestRoundTripUnchanged = $true
    OriginalStorageModified = $false
    SnapshotScope = 'Selected complete requests from the first native snapshot only'
    NativeImportTested = $false
}