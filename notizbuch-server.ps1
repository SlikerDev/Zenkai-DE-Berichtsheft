# Kleiner lokaler Server fuer das Notizbuch.
# Liefert notizbuch.html aus und speichert alle Eintraege in notizbuch.json
# im selben Ordner. Einmal pro Tag wird eine Sicherung im Ordner "Sicherungen" angelegt.
# Nur von diesem PC aus erreichbar (localhost).

param([switch]$NoBrowser, [int]$Port = 8765)

$ErrorActionPreference = 'Stop'
$dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath  = Join-Path $dir 'notizbuch.html'
$dataPath  = Join-Path $dir 'notizbuch.json'
$backupDir = Join-Path $dir 'Sicherungen'
$copyDir   = Join-Path $dir 'Kopien'
$utf8      = New-Object System.Text.UTF8Encoding($false)
$url       = "http://localhost:$Port/"

$Host.UI.RawUI.WindowTitle = 'Notizbuch'

# Laeuft das Notizbuch schon? Dann nur den Browser oeffnen.
try {
    $ping = Invoke-WebRequest -Uri ($url + 'api/ping') -UseBasicParsing -TimeoutSec 2
    if ($ping.Content -eq 'notizbuch') {
        if (-not $NoBrowser) { Start-Process $url }
        exit 0
    }
} catch { }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() }
catch {
    Write-Host "Port $Port ist belegt. Bitte das andere Programm schliessen und erneut starten." -ForegroundColor Red
    Read-Host 'Enter zum Beenden'
    exit 1
}

Write-Host ''
Write-Host '  Notizbuch laeuft.' -ForegroundColor Green
Write-Host "  Adresse:   $url"
Write-Host "  Speichert: $dataPath"
Write-Host ''
Write-Host '  Dieses Fenster offen lassen (minimiert ist ok), solange du schreibst.'
Write-Host '  Zum Beenden das Fenster schliessen.'
Write-Host ''

if (-not $NoBrowser) { Start-Process $url }

function Send-Bytes($res, [byte[]]$bytes, [string]$type, [int]$code = 200) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Text($res, [string]$text, [string]$type = 'text/plain; charset=utf-8', [int]$code = 200) {
    Send-Bytes $res ($utf8.GetBytes($text)) $type $code
}

# Dateinamen bereinigen (keine Pfade, keine verbotenen Zeichen)
function Clean-Name([string]$n) {
    if (-not $n) { $n = 'Kopie' }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace([string]$c, '') }
    $n = $n.Trim().TrimEnd('.').Trim()
    if ($n.Length -gt 80) { $n = $n.Substring(0, 80).Trim() }
    if (-not $n) { $n = 'Kopie' }
    return $n
}
function Header-Name($req) {
    $raw = [string]$req.Headers['X-Name']
    if (-not $raw) { return '' }
    return [Uri]::UnescapeDataString($raw)
}

function Save-Notebook([string]$body) {
    # Taegliche Sicherung des bisherigen Stands
    if (Test-Path $dataPath) {
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
        $daily = Join-Path $backupDir ('notizbuch-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
        if (-not (Test-Path $daily)) { Copy-Item $dataPath $daily }
    }
    # Erst in Hilfsdatei schreiben, dann austauschen -> nie eine halb geschriebene Datei
    $tmp = $dataPath + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $body, $utf8)
    if (Test-Path $dataPath) { [System.IO.File]::Replace($tmp, $dataPath, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $dataPath) }
}

while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) { }
    $ctx = $task.GetAwaiter().GetResult()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath
        $origin = $req.Headers['Origin']
        $sameOrigin = (-not $origin) -or ($origin.TrimEnd('/') -eq $url.TrimEnd('/'))

        if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/notizbuch.html')) {
            Send-Bytes $res ([System.IO.File]::ReadAllBytes($htmlPath)) 'text/html; charset=utf-8'
        }
        elseif ($path -eq '/api/ping') {
            Send-Text $res 'notizbuch'
        }
        elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/load') {
            if (Test-Path $dataPath) {
                Send-Bytes $res ([System.IO.File]::ReadAllBytes($dataPath)) 'application/json; charset=utf-8'
            } else {
                Send-Text $res 'keine Datei' 'text/plain; charset=utf-8' 404
            }
        }
        elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/save') {
            if (-not $sameOrigin) { Send-Text $res 'verboten' 'text/plain; charset=utf-8' 403 }
            else {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $utf8)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $trim = $body.Trim()
                if ($trim.StartsWith('{') -and $trim.EndsWith('}') -and $trim.Contains('"tabs"')) {
                    Save-Notebook $body
                    Write-Host ('  gespeichert ' + (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
                    Send-Text $res 'ok'
                } else {
                    Send-Text $res 'ungueltig' 'text/plain; charset=utf-8' 400
                }
            }
        }
        elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/copy') {
            # PDF-Kopie einer Seite im Ordner "Kopien" ablegen
            if (-not $sameOrigin) { Send-Text $res 'verboten' 'text/plain; charset=utf-8' 403 }
            else {
                $ms = New-Object System.IO.MemoryStream
                $req.InputStream.CopyTo($ms)
                $bytes = $ms.ToArray()
                if ($bytes.Length -lt 5 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 5) -ne '%PDF-') {
                    Send-Text $res 'keine PDF' 'text/plain; charset=utf-8' 400
                } else {
                    if (-not (Test-Path $copyDir)) { New-Item -ItemType Directory -Path $copyDir | Out-Null }
                    $name = Clean-Name (Header-Name $req)
                    if ($name.ToLower().EndsWith('.pdf')) { $name = $name.Substring(0, $name.Length - 4) }
                    $file = "$name.pdf"; $i = 2
                    while (Test-Path -LiteralPath (Join-Path $copyDir $file)) { $file = "$name ($i).pdf"; $i++ }
                    [System.IO.File]::WriteAllBytes((Join-Path $copyDir $file), $bytes)
                    Write-Host ("  Kopie erstellt: Kopien\" + $file) -ForegroundColor DarkGray
                    Send-Text $res ('{"file":' + (ConvertTo-Json $file) + '}') 'application/json; charset=utf-8'
                }
            }
        }
        elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/open') {
            # Kopien-Ordner oder eine Kopie im Explorer / PDF-Programm oeffnen
            if (-not $sameOrigin) { Send-Text $res 'verboten' 'text/plain; charset=utf-8' 403 }
            else {
                if (-not (Test-Path $copyDir)) { New-Item -ItemType Directory -Path $copyDir | Out-Null }
                if ($req.Headers['X-Open'] -eq 'file') {
                    $f = Join-Path $copyDir (Clean-Name (Header-Name $req))
                    if ($f.ToLower().EndsWith('.pdf') -and (Test-Path -LiteralPath $f)) { Start-Process -FilePath $f }
                } else {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $copyDir + '"')
                }
                Send-Text $res 'ok'
            }
        }
        else {
            Send-Text $res 'nicht gefunden' 'text/plain; charset=utf-8' 404
        }
    }
    catch {
        Write-Host ('  Fehler: ' + $_.Exception.Message) -ForegroundColor Red
        try { Send-Text $res 'Fehler' 'text/plain; charset=utf-8' 500 } catch { }
    }
    finally {
        try { $res.Close() } catch { }
    }
}
