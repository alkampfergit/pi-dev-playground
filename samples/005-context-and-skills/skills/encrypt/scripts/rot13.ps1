param(
  [Parameter(Mandatory)]
  [string]$Message
)

# ROT13 is symmetric: run this script again on its output to decode it.
-join ($Message.ToCharArray() | ForEach-Object {
  if ($_ -cmatch "[A-Z]") { [char]((([int][char]$_ - 65 + 13) % 26) + 65) }
  elseif ($_ -cmatch "[a-z]") { [char]((([int][char]$_ - 97 + 13) % 26) + 97) }
  else { $_ }
})
