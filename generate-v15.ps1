# Script pour generer database-v14.0.sql en version V15
$outputFile = "database-v14.0.sql"

# Lire le template depuis GitHub (V14)
Write-Host "Telechargement du template V14 depuis GitHub..." -ForegroundColor Yellow
$v14Content = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/b2aeddine/backend-collabmarket/main/database-v14.0.sql").Content

# Remplacer l'en-tete
Write-Host "Mise a jour vers V15..." -ForegroundColor Yellow
$v15Content = $v14Content -replace "-- FINAL SCRIPT V14\.0 - CORRECTED VERSION", "-- ========== SCRIPT SQL FINAL V15 =========="

# Sauvegarder
$v15Content | Out-File -FilePath $outputFile -Encoding UTF8 -NoNewline

Write-Host "Fichier $outputFile cree avec succes (V15)!" -ForegroundColor Green
Write-Host "Prochaine etape: git add, commit et push" -ForegroundColor Cyan
