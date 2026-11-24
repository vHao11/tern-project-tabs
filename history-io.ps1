# Arguments arrive on stdin as UTF-8 data, separately from this script.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$items = [Console]::In.ReadToEnd().Split([char]0)
$skip = [IO.FileAttributes]::ReparsePoint

function Write-Prefix([string] $file) {
    $stream = $null
    try {
        $info = [IO.FileInfo]::new($file)
        if (!$info.Exists -or ($info.Attributes -band $skip)) { return }
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($file, 'Open', 'Read', $share)
        $reader = [IO.BinaryReader]::new($stream)
        [Console]::Write([Convert]::ToBase64String($reader.ReadBytes(32768)))
    } catch [IO.IOException] {} catch [UnauthorizedAccessException] {} finally {
        if ($null -ne $stream) { $stream.Dispose() }
        [Console]::WriteLine()
    }
}

switch ($env:PT_HISTORY_OP) {
    'archive' {
        $dir = $env:PT_ARCHIVE_DIR
        $batch = $env:PT_ARCHIVE_BATCH
        if ($batch -notmatch '^[0-9a-f]{64}$') { throw 'Invalid archive batch' }
        [void][IO.Directory]::CreateDirectory($dir)
        $target = [IO.Path]::Combine($dir, $batch + '.set')
        if ([IO.File]::Exists($target)) { return }
        $tempFile = [IO.Path]::Combine($dir, [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tempFile, $items[0], [Text.UTF8Encoding]::new($false))
            try { [IO.File]::Move($tempFile, $target) }
            catch [IO.IOException] { if (![IO.File]::Exists($target)) { throw } }
        } finally { [IO.File]::Delete($tempFile) }
    }
    'list' {
        $root = [IO.DirectoryInfo]::new($items[0])
        try { $folders = $root.GetDirectories() } catch [IO.DirectoryNotFoundException] { return }
        foreach ($folder in $folders) {
            if ($folder.Attributes -band $skip) { continue }
            try { $files = $folder.GetFiles('*.jsonl') }
            catch [UnauthorizedAccessException] { continue } catch [IO.DirectoryNotFoundException] { continue }
            foreach ($file in $files) {
                if ($file.Extension -ne '.jsonl' -or ($file.Attributes -band $skip)) { continue }
                try { $length = $file.Length } catch [IO.IOException] { continue }
                $seconds = [DateTimeOffset]::new($file.LastWriteTimeUtc).ToUnixTimeMilliseconds() / 1000
                $mtime = $seconds.ToString([Globalization.CultureInfo]::InvariantCulture)
                [Console]::Write(("{0}`t{1}`t{2}{3}" -f $mtime, $length, $file.FullName, [char]0))
            }
        }
    }
    'read' {
        foreach ($file in $items) {
            [Console]::Write(':')
            Write-Prefix $file
        }
    }
    'check' {
        if (![IO.Directory]::Exists($items[1])) { [Console]::Write('missing-cwd'); return }
        Write-Prefix $items[0]
    }
}
