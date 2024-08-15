#!/usr/bin/env bash
jq '
  def firstDash(k): if has(k) then {("First" + k): (.[k]|split("-")[0])} else null end; 
  def firstWord(k): if has(k) then {("First" + k): (.[k]|split(" ")[0])} else null end; 
  def lastWord(k): if has(k) then {("Last" + k): (.[k]|split(" ")[-1])} else null end; 
  def genus(k): if has(k) then {("genus"): (.[k]|split(" ")[0])} else null end;
  map(.
    + firstDash("Portuguese (Portuguese)")
    + firstDash("Portuguese (Lusophone)")
    + firstWord("Spanish")
    + firstWord("French")
    + lastWord("English")
    + genus("species")
  )
' "$1"