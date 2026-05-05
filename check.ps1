# ════════════════════════════════════════════════════════════
#  SİSTEM ANALİZ DUMP — paketler, feature'lar, servisler
#  Çıktıyı masaüstüne kaydeder: system-dump.txt
# ════════════════════════════════════════════════════════════

$out = "$env:USERPROFILE\Desktop\system-dump.txt"
$lines = [System.Collections.Generic.List[string]]::new()

function Section ([string]$title) {
    $lines.Add('')
    $lines.Add('════════════════════════════════════════')
    $lines.Add("  $title")
    $lines.Add('════════════════════════════════════════')
}

# ── DISM Packages ────────────────────────────────────────────
Section 'DISM PACKAGES (dism /Get-Packages)'
$pkgs = & dism.exe /Online /Get-Packages 2>$null |
        Where-Object { $_ -match '^\s*Package Identity\s*:' } |
        ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() } |
        Sort-Object
$lines.Add("Toplam: $($pkgs.Count)")
$pkgs | ForEach-Object { $lines.Add("  $_") }

# ── Optional Features (Enabled only) ────────────────────────
Section 'OPTIONAL FEATURES — ENABLED'
$feats = & dism.exe /Online /Get-Features 2>$null
$currentFeat = $null
$enabledFeats = [System.Collections.Generic.List[string]]::new()
foreach ($line in $feats) {
    if ($line -match '^\s*Feature Name\s*:\s*(.+)') {
        $currentFeat = $Matches[1].Trim()
    }
    if ($line -match '^\s*State\s*:\s*Enabled' -and $currentFeat) {
        $enabledFeats.Add($currentFeat)
        $currentFeat = $null
    }
}
$enabledFeats | Sort-Object | ForEach-Object { $lines.Add("  $_") }
$lines.Add("Toplam enabled: $($enabledFeats.Count)")

# ── Servisler (Running veya StartType != Disabled) ───────────
Section 'SERVİSLER — RUNNING veya AUTO/MANUAL'
Get-Service | Where-Object { $_.Status -eq 'Running' -or $_.StartType -in 'Automatic','Manual' } |
    Sort-Object DisplayName |
    ForEach-Object { $lines.Add("  [$($_.StartType.ToString().PadRight(9))] [$($_.Status.ToString().PadRight(7))] $($_.Name) — $($_.DisplayName)") }

# ── AppX Packages (tüm kullanıcılar) ────────────────────────
Section 'APPX PACKAGES (tüm kullanıcılar)'
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { $lines.Add("  $($_.Name)  [$($_.Version)]") }

# ── Kaydet ───────────────────────────────────────────────────
$lines | Set-Content -Path $out -Encoding UTF8
Write-Host "`n[ok] Dump kaydedildi: $out" -ForegroundColor Green
Write-Host "     Paket sayisi: $($pkgs.Count)  |  Enabled feature: $($enabledFeats.Count)" -ForegroundColor Cyan
