$OctopusUrl = "https://your.octopus.app"
$ApiKey = "API-YOUR-KEY-HERE"

# We use the API Key to authenticate the initial request to get the token
$headers = @{
    "X-Octopus-ApiKey" = $ApiKey
    "Content-Type"     = "application/json"
}

$endpoint = "$OctopusUrl/api/users/access-token"

try {
    Write-Host "Requesting Access Token from Octopus..." -ForegroundColor Cyan
    
    $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers
    
    $accessToken = $response.AccessToken
    
    Write-Host "Successfully generated Bearer Token!" -ForegroundColor Green
    Write-Host "Token: $accessToken"

} catch {
    Write-Error "Failed to retrieve Access Token. Error: $_"
}
