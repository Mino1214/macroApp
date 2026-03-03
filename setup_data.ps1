# nexus_flutter data 폴더 설정
# macro 프로젝트의 pic, wordlist를 nexus_flutter/data로 복사

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$macroDir = Split-Path -Parent $scriptDir
$dataDir = Join-Path $scriptDir "data"

New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "pic\kr") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "pic\trustwallet") | Out-Null

if (Test-Path (Join-Path $macroDir "pic\kr")) {
    Copy-Item -Path (Join-Path $macroDir "pic\kr\*") -Destination (Join-Path $dataDir "pic\kr") -Recurse -Force
    Write-Host "pic/kr 복사 완료"
}
if (Test-Path (Join-Path $macroDir "pic\trustwallet")) {
    Copy-Item -Path (Join-Path $macroDir "pic\trustwallet\*") -Destination (Join-Path $dataDir "pic\trustwallet") -Recurse -Force
    Write-Host "pic/trustwallet 복사 완료"
}
if (Test-Path (Join-Path $macroDir "wordlist.txt")) {
    Copy-Item -Path (Join-Path $macroDir "wordlist.txt") -Destination $dataDir -Force
    Write-Host "wordlist.txt 복사 완료"
}

Write-Host "data 폴더 설정 완료: $dataDir"
