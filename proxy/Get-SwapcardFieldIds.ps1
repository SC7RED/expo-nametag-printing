<#
.SYNOPSIS
    Lists the IDs of the event's select fields (such as Major and School Year). They go in
    ExpoNametag.env as SWAPCARD_MAJOR_ID and SWAPCARD_YEAR_ID. Run it once a year, after a few
    students have registered. It asks for the Swapcard API key and doesn't save it anywhere.

.EXAMPLE
    .\proxy\Get-SwapcardFieldIds.ps1 -EventId <this year's Swapcard event ID>
#>
param(
    [Parameter(Mandatory)][string]$EventId
)

$ErrorActionPreference = 'Stop'

$secureKey = Read-Host 'Swapcard API key (typing is hidden)' -AsSecureString
$key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))

# Field values come with each attendee, so read a page of attendees and collect the field definitions.
$query = @'
query Fields($eventId: ID!) {
  eventPerson(eventId: $eventId) {
    nodes {
      withEvent(eventId: $eventId) {
        fields {
          ... on MultipleSelectField { definition { id translations { name } } }
          ... on SelectField { definition { id translations { name } } }
        }
      }
    }
  }
}
'@
$body = @{ query = $query; variables = @{ eventId = $EventId } } | ConvertTo-Json -Depth 5
$result = Invoke-RestMethod -Method Post -Uri 'https://developer.swapcard.com/event-admin/graphql' `
    -Headers @{ Authorization = $key } -ContentType 'application/json' -Body $body

if ($result.PSObject.Properties['errors'] -and $result.errors) {
    throw "Swapcard said: $(($result.errors | ForEach-Object { $_.message }) -join '; ')"
}

$fields = @($result.data.eventPerson.nodes.withEvent.fields |
    Where-Object { $_ -and $_.PSObject.Properties['definition'] } |
    ForEach-Object { [pscustomobject]@{ Field = $_.definition.translations[0].name; Id = $_.definition.id } } |
    Sort-Object Id -Unique)

if ($fields.Count -eq 0) {
    Write-Host 'No select fields found. Are there registered students yet, and is the event ID right?'
} else {
    $fields | Format-Table -AutoSize
}
