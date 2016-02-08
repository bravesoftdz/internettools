unit xquery__regex;


{
Copyright (C) 2008 - 2016 Benito van der Zander (BeniBela)
                          benito@benibela.de
                          www.benibela.de

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

}

{$mode objfpc}{$H+}


//Here you can choose which regex library to use
{$if not defined(USE_SOROKINS_REGEX) and not defined(USE_SOROKINS_DREGEX) and not defined(USE_FLRE) and not defined(USE_FLRE_WITH_CACHE)}
//{$DEFINE USE_SOROKINS_REGEX}
//{$DEFINE USE_SOROKINS_DREGEX}
//{$DEFINE USE_FLRE}
{$DEFINE USE_FLRE_WITH_CACHE}
{$endif}

interface

{$IFDEF USE_FLRE_WITH_CACHE}
{$DEFINE USE_FLRE}
{$ENDIF}

uses
  Classes, SysUtils, xquery, bbutils
    {$IFDEF USE_SOROKINS_REGEX},regexpr{$ENDIF} //Sorokins's regex library. Contained in fpc nowadays, or
    {$IFDEF USE_SOROKINS_DREGEX},dregexpr{$ENDIF}    //supplied in this unit
    {$IFDEF USE_FLRE},FLRE{$ENDIF} //FLRE from https://github.com/BeRo1985/flre
  ;
{$IFDEF USE_SOROKINS_DREGEX}
{$DEFINE USE_SOROKINS_REGEX}
{$ENDIF}
{$IFDEF USE_SOROKINS_REGEX}
type TWrappedRegExpr = TRegExpr;
     EWrappedRegExpr = ERegExpr;
     TWrappedMatchArray = TStringArray;
{$ENDIF}

{$IFDEF USE_FLRE}
type TWrappedRegExpr = TFLRE;
     EWrappedRegExpr = EFLRE;
     TWrappedMatchArray = TFLREStrings;
{$DEFINE REGEX_SUPPORTS_UNICODE}
{$ENDIF}

type TWrappedRegExprFlag  = (wrfSingleLine, wrfMultiLine, wrfIgnoreCase, // standard
                             wrfStripWhitespace, wrfQuote, wrfSkipSyntaxNormalization);
     TWrappedRegExprFlags = set of TWrappedRegExprFlag;



function regexprreencode(regexpr: string; flags: TWrappedRegExprFlags): string;



function wregexprParseInternal(const pattern: string; flags: TWrappedRegExprFlags): TWrappedRegExpr;
function wregexprParse(pattern: string; flags: TWrappedRegExprFlags): TWrappedRegExpr;
function wregexprParse(const args: TXQVArray; flagsPos: integer; allowEmptyMatch: boolean;  toescape: PBoolean = nil;  all: PBoolean = nil): TWrappedRegExpr;
function wregexprClone(regexpr: TWrappedRegExpr): TWrappedRegExpr;
procedure wregexprFree(wregexp: TWrappedRegExpr);

function wregexprMatches(regexpr: TWrappedRegExpr; input: string): Boolean; //might be removed in future
function wregexprExtract(regexpr: TWrappedRegExpr; input: string; out matches: TWrappedMatchArray): boolean; //might be removed in future

//XQuery standard function
function xqFunctionReplace(const args: TXQVArray): IXQValue;
function xqFunctionMatches(const args: TXQVArray): IXQValue;
function xqFunctionTokenize(const args: TXQVArray): IXQValue;
function xqFunctionAnalyze_String(const context: TXQEvaluationContext; const args: TXQVArray): IXQValue;

//My extension function
function xqFunctionExtract(const args: TXQVArray): IXQValue;

const UsingFLRE = {$IFDEF USE_FLRE}true{$ELSE}false{$endif} ;

implementation

uses math, simplehtmltreeparser, strutils;

{$IFDEF USE_FLRE_WITH_CACHE}
var flreCache: TFLRECacheHashMap;
    flreCacheList: TFPList;
    flreCacheLock: TRTLCriticalSection;
{$ENDIF}

//procedure debugLogMatch(regexpr: TWrappedRegExpr; input: string);
//writeln(stderr, '#####>', regexpr.RegularExpressionSource, ' on ',input, '<#####');

procedure strAddFast(var result: RawByteString; var reslen: integer; const s: RawByteString);
begin
  if s <> '' then begin
    if reslen + length(s) > length(result) then SetLength(result, max(length(result)*2, reslen + length(s)));
    move(s[1], result[reslen+1], length(s));
    reslen += length(s);
  end;
end;

function regexprreencode(regexpr: string; flags: TWrappedRegExprFlags): string;
const WHITESPACE = [#$20,#$9,#$A,#$D];
var pos: integer;
    reslen: integer;
    openedCharClasses: integer;
    capturingGroupsCount, closedCapturingGroupsCount: integer;


    capturingGroups: array of record
      startAt: integer; //index in result if open; = 0 if closed
      caseInsensiveVersion: string;
      caseInsensiveVersionLength: integer;
    end;
    specialCaptureHandlingActive: boolean;

  procedure addtocapturegroups(const s: RawByteString);
  var
    i: Integer;
  begin
    for i := 0 to capturingGroupsCount - 1 do
      if capturingGroups[i].startAt > 0 then
        strAddFast(capturingGroups[i].caseInsensiveVersion, capturingGroups[i].caseInsensiveVersionLength, s);
  end;

  procedure addc(const c: ansichar); inline;
  begin
    if reslen = length(result) then SetLength(result, length(result)*2);
    reslen += 1;
    result[reslen] := c;
    if specialCaptureHandlingActive then
      addtocapturegroups(c);
  end;
  procedure adds(const s: RawByteString); inline;
  begin
    strAddFast(result, reslen, s);
    if specialCaptureHandlingActive then
      addtocapturegroups(s);
  end;

  procedure abort;
  begin
    raise EXQEvaluationException.create('FORX0002', 'Invalid regexpr: '+regexpr+' after ' + copy(regexpr, 1, pos));
  end;

  function gotonextchar: char; inline;
  begin
    inc(pos);
    if (openedCharClasses = 0) and (wrfStripWhitespace in flags) then
      while (pos <= length(regexpr)) and (regexpr[pos] in WHITESPACE) do inc(pos);
    if pos > length(regexpr) then abort;
    result := regexpr[pos];
  end;

  procedure gotonextcharorstop; inline;
  begin
    inc(pos);
    if (openedCharClasses = 0) and (wrfStripWhitespace in flags)  then
      while (pos <= length(regexpr)) and (regexpr[pos] in WHITESPACE) do inc(pos);
  end;

  function curchar: char; inline;
  begin
    result := regexpr[pos];
  end;

  procedure expect(c: char);
  begin
    if (gotonextchar <> c) then abort;
  end;


  procedure copyCurvy();
  begin
    while curchar <> '}' do begin
      addc(curchar);
      gotonextchar;
    end;
    addc(curchar);
  end;

  procedure charClassEsc(inclass: boolean);
  var
    c: Char;
    range: String;
    index: Integer;
    i: Integer;
  begin
    c := gotonextchar;
    case  c of
       //XML Schemas
      '\','|','.','-','^','?','*','+','{','}','(',')','[',']': begin
        addc('\');
        addc(c);
      end;
      'n': addc(#$A);
      'r': addc(#$D);
      't': addc(#$9);
      'p', 'P': begin
        if not inclass and (wrfIgnoreCase in flags) then begin
          if {$ifdef USE_FLRE}(capturingGroupsCount > closedCapturingGroupsCount){$else}false{$endif}  then begin
            if not specialCaptureHandlingActive then begin
              for i := 0 to capturingGroupsCount - 1 do begin
                if capturingGroups[i].startAt > 0 then begin
                  capturingGroups[i].caseInsensiveVersion := copy(result, capturingGroups[i].startAt, reslen - capturingGroups[i].startAt + 1);
                  capturingGroups[i].caseInsensiveVersionLength := length(capturingGroups[i].caseInsensiveVersion);
                end;
              end;
            end;
            specialCaptureHandlingActive := true;
          end;
          strAddFast(result, reslen, '(?-i)');
        end;
        addc('\');
        addc(c);
        expect('{');
        copyCurvy();
        if not inclass and (wrfIgnoreCase in flags) then strAddFast(result, reslen, '(?i)');
      end;
      's', 'S', 'd', 'D', 'w', 'W': begin
        addc('\');
        addc(c);
      end;
      'i','I','c','C': begin //i: xml's namestartchar, c: namechar
        if not inclass then addc('[');
        range := '';
        case c of
          {$IFDEF REGEX_SUPPORTS_UNICODE}
          'i': range := ':A-Z_a-z\UC0-\UD6\UD8-\UF6\UF8-\U2FF\U370-\U37D\U37F-\U1FFF\U200C-\U200D\U2070-\U218F\U2C00-\U2FEF\U3001-\UD7FF\UF900-\UFDCF\UFDF0-\UFFFD\U10000-\UEFFFF';
          'I': range := '\U1-\U39\U3B-\U40\U5B-\U5E\U60-\U60\U7B-\UBF\UD7-\UD7\UF7-\UF7\U300-\U36F\U37E-\U37E\U2000-\U200B\U200E-\U206F\U2190-\U2BFF\U2FF0-\U3000\UD800-\UF8FF\UFDD0-\UFDEF\UFFFE-\UFFFF\UF0000-\UFFFFF';
          'c': range := '\U2D.0-9\UB7\U0300-\U036F\U203F-\U2040' +
                        ':A-Z_a-z\UC0-\UD6\UD8-\UF6\UF8-\U2FF\U370-\U37D\U37F-\U1FFF\U200C-\U200D\U2070-\U218F\U2C00-\U2FEF\U3001-\UD7FF\UF900-\UFDCF\UFDF0-\UFFFD\U10000-\UEFFFF';
          'C': range := '\U1-\U2E\U2F-\U2F\U3B-\U40\U5B-\U5E\U60-\U60\U7B-\UBF\UD7-\UD7\UF7-\UF7\U300-\U36F\U37E-\U37E\U2000-\U200B\U200E-\U206F\U2190-\U2BFF\U2FF0-\U3000\UD800-\UF8FF\UFDD0-\UFDEF\UFFFE-\UFFFF\UF0000-\UFFFFF';
                            {negation:  for s in strSplit(range,'-') do begin
                                          a:=strSplit(s,'\U');
                                          write('\U',IntToHex( StrToInt('$0'+ a[1])+1,0),'-\U',IntToHex( StrToInt('$0'+a[2])-1,0))
                                        end;   }
          {$ELSE}
          //ascii approximation of those above
          'i': range := ':A-Z_a-z'#$7F'-'#$FF;
          'I': range := #1'-'#64'\x5B-\x5E`\x7B-\x7E';
          'c': range := '-.0-9:A-Z_a-z'#$7F'-'#$FF;
          'C': range := #1'-'#44'/'#58'-'#64'\x5B-\x5E`\x7B-\x7E';
          {$ENDIF}
        end;
        adds(range);
        if not inclass then addc(']');
      end;
      //XQuery extensions
      '$': adds('\$');
      '1'..'9': begin
        if inclass then abort;
        if not specialCaptureHandlingActive then addc('\')
        else adds('(?P=');
        addc(c);
        index := ord(c) - ord('0');
        gotonextcharorstop;
        while (pos <= length(regexpr)) and (curchar in ['0'..'9']) and (index * 10 + ord(curchar) - ord('0') <= capturingGroupsCount ) do begin
          index := index * 10 + ord(curchar) - ord('0');
          addc(curchar);
          gotonextcharorstop;
        end;
        if (index > capturingGroupsCount) or (capturingGroups[index-1].startAt > 0) then abort;
        if specialCaptureHandlingActive then begin
          addc(':');
          adds(copy(capturingGroups[index-1].caseInsensiveVersion, 1, capturingGroups[index-1].caseInsensiveVersionLength));
          addc(')');
        end else if (pos <= length(regexpr)) and (regexpr[pos] in ['0'..'9']) then adds('(?:)');
        dec(pos);
      end;
      else abort;
    end;
  end;

  procedure charClassExpr;
  begin
    //c = '['
    addc('[');
    inc(openedCharClasses);
    gotonextchar;
    if curchar = '^' then begin
      addc(curchar); //negated class
      gotonextchar;
    end;
    case curchar of
      ']': abort; //empty
      '-': if ((pos + 1) < length(regexpr)) and (regexpr[pos+1] = '[') then abort; //[-[   empty subtraction
    end;
    while true do begin
      case curchar of
        ']': begin
          addc(']');
          dec(openedCharClasses);
          exit;
        end;
        '[': abort;
        '\': charClassEsc(true);
        '-': begin
          addc('-');
          case gotonextchar  of
            '[': begin //subtraction
              charClassExpr;
              exit;
            end;
            '-': begin  //2nd -
              addc('-');
              expect('[');
              addc('[');
            end;
            ']': dec(pos);//- is char in class, next iteration
            else dec(pos); //single char, next iteration
          end;
        end;
        else addc(curchar);
      end;
      gotonextchar;
    end;
  end;

var
  c: Char;
  groups: array of integer; // >= 0 capturing; < 0 not-capturing
  groupcount: integer;
begin
  SetLength(result, length(regexpr));
  groups := nil;
  reslen := 0;
  openedCharClasses := 0;
  groupcount := 0;
  capturingGroupsCount := 0;
  capturingGroups := nil;
  closedCapturingGroupsCount := 0;
  specialCaptureHandlingActive := false;
  pos := 1;
  while pos <= length(regexpr) do begin
    c := regexpr[pos];
    case c of
      '|', '?', '*', '+', '.': addc(c);
      '{': copyCurvy();
      '(': begin
        addc('(');
        if pos >= length(regexpr) then abort;
        if groupcount >= length(groups) then SetLength(groups, groupcount + 8);
        if regexpr[pos+1] = '?' then begin
          expect('?'); addc('?');
          expect(':'); addc(':');
          groups[groupcount] := -1;
          if ((pos+1) > length(regexpr)) or (regexpr[pos+1] = '?') then abort;
        end else  begin
          if specialCaptureHandlingActive then addtocapturegroups('?:'); //do not want to create new groups in the capture groups
          groups[groupcount] := capturingGroupsCount;
          if capturingGroupsCount >= length(capturingGroups) then SetLength(capturingGroups, capturingGroupsCount + 8);
          capturingGroups[capturingGroupsCount].startAt := reslen + 1;
          inc(capturingGroupsCount);
        end;
        inc(groupcount);
      end;
      ')': begin
        if groupcount <= 0 then abort;
        dec(groupcount);
        if groups[groupcount] >= 0 then begin
          capturingGroups[groups[groupcount]].startAt := 0;
          inc(closedCapturingGroupsCount);
        end;
        addc(c);
      end;
      '[': charClassExpr;
      '\': charClassEsc(false);
      ' ',#9,#$A,#$D: if not (wrfStripWhitespace in flags)  then addc(c);
      else addc(c);
    end;
    inc(pos);
  end;
  if length(result) <> reslen then SetLength(result, reslen);
end;



{$IFDEF USE_SOROKINS_REGEX}

function wregexprParseInternal(const pattern: string; flags: TWrappedRegExprFlags): TWrappedRegExpr;
var
  regEx: TRegExpr;
begin
  regEx:=TRegExpr.Create();
  regEx.Expression := pattern;
  regEx.ModifierS := wrfSingleLine in flags;
  regEx.ModifierM := wrfMultiLine in flags;
  regEx.ModifierI := wrfIgnoreCase in flags;
  result := TWrappedRegExpr(regex);
end;

{$ENDIF}

{$IFDEF USE_FLRE}
function wregexprParseInternal(const pattern: string; flags: TWrappedRegExprFlags): TWrappedRegExpr;
var flreflags: TFLREFlags;
begin
  flreflags := [rfUTF8];
  if wrfSingleLine in flags then include(flreflags, rfSINGLELINE);
  if wrfMultiLine in flags then Include(flreflags, rfMULTILINE);
  if wrfIgnoreCase in flags then Include(flreflags, rfIGNORECASE);
  result := TFLRE.Create(pattern, flreflags);
end;

{$ENDIF}


function wregexprParse(pattern: RawByteString; flags: TWrappedRegExprFlags): TWrappedRegExpr;
var
  temp: RawByteString;
  c: Char;
  {$ifdef USE_FLRE_WITH_CACHE}
  hashkey: RawByteString;
  tempRegExpr: TWrappedRegExpr;
  {$endif}
begin
  {$ifdef USE_FLRE_WITH_CACHE}
  EnterCriticalsection(flreCacheLock);
  //cache code adapted from FLRE
  try
    HashKey:=FLREPtrCopy(pointer(@flags),0,SizeOf(flags))+#0#1#0+pattern;
    result := flreCache.Values[hashkey];
    if result <> nil then exit;
  finally
    LeaveCriticalsection(flreCacheLock);
  end;
  {$endif}
  if wrfQuote in flags then begin
    temp := pattern;
    pattern := '';
    for c in temp do
      if c in ['.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '\', '|'] then pattern += '\' + c
      else pattern += c;
    include(flags, wrfSkipSyntaxNormalization);
  end;
  result := nil;
  try
    if not (wrfSkipSyntaxNormalization in flags) then pattern := regexprreencode(pattern, flags);
    result := wregexprParseInternal(pattern, flags);
    {$ifdef USE_FLRE_WITH_CACHE}
    EnterCriticalsection(flreCacheLock);
    //cache code adapted from FLRE
    try
      tempRegExpr := flreCache.Values[hashkey];
      if tempRegExpr = nil then begin
        flreCache.Values[hashkey] := result;
        flreCacheList.Add(result);
      end else begin
        result.free;
        result := tempRegExpr;
      end;
    finally
      LeaveCriticalsection(flreCacheLock);
    end;
    {$endif}
  except
    on e: EWrappedRegExpr do raise EXQEvaluationException.create('FORX0002', 'Regexp error '+e.Message+ ' in '+pattern);
  end;
end;

function wregexprParse(const args: TXQVArray; flagsPos: integer; allowEmptyMatch: boolean;  toescape: PBoolean = nil;  all: PBoolean = nil): TWrappedRegExpr;
var
  flags: TWrappedRegExprFlags;
  c: Char;
begin
  flags := [];
  if all <> nil then all^ := false;
  if high(args) >= flagsPos then begin
    for c in args[flagsPos].toString do
      case c of
      's': Include(flags, wrfSingleLine);
      'm': Include(flags, wrfMultiLine);
      'i': Include(flags, wrfIgnoreCase);
      'x': Include(flags, wrfStripWhitespace);
      'q': Include(flags, wrfQuote);
      '!': include(flags, wrfSkipSyntaxNormalization);
      else if (c = '*') and (all <> nil) then all^ := true
      else raise EXQEvaluationException.create('FORX0001', 'Invalid flag ' + c + ' in ' + args[flagsPos].debugAsStringWithTypeAnnotation());
      end;
  end;

  if toescape <> nil then toescape^ := wrfIgnoreCase in flags;

  result := wregexprParse(args[1].toString, flags);
  if not allowEmptyMatch then begin
    if result.
      {$IF defined(USE_SOROKINS_REGEX)}Exec{$ELSEIF defined(USE_FLRE)}Test{$ENDIF}
      ('') then begin
        wregexprFree(result);
        raise EXQEvaluationException.create('FORX0003', 'Regexp must not match the empty string: '+args[1].toString);
      end;
  end;
end;

function wregexprClone(regexpr: TWrappedRegExpr): TWrappedRegExpr;
begin
  {$if defined(USE_FLRE_WITH_CACHE)}
  result := regexpr;
  {$elseif defined(USE_FLRE)}
  result := TWrappedRegExpr.Create(regexpr.RegularExpressionSource, regexpr.RegularExpressionFlags);
  {$else}
  result := TWrappedRegExpr.Create();
  result.expression := regexpr.expression;
  result.ModifierStr := regexpr.ModifierStr;
  {$endif}
end;

function wregexprMatches(regexpr: TWrappedRegExpr; input: string): Boolean;
begin
  try
    //debugLogMatch
    {$IFDEF USE_SOROKINS_REGEX}
    result := regexpr.Exec(input);
    {$ENDIF}
    {$IFDEF USE_FLRE}
    result := regexpr.UTF8Find(input) > 0;
    {$ENDIF}
  except
    on e: EWrappedRegExpr do raise EXQEvaluationException.Create('FORX0002', e.Message);
  end;
end;

function wregexprExtract(regexpr: TWrappedRegExpr; input: string; out matches: TWrappedMatchArray): boolean;
var
  {$IFDEF USE_FLRE}extractions: TFLREMultiStrings;{$ENDIF}
  {$IFDEF USE_SOROKINS_REGEX}i: Integer;{$ENDIF}
begin
  //debugLogMatch
  try
    {$IFDEF USE_SOROKINS_REGEX}
    result := regexpr.Exec(input);
    if not Result then matches := nil
    else begin
      SetLength(matches, regexpr.SubExprMatchCount+1);
      for i := 0 to high(matches) do matches[i] := regexpr.match[i];
    end;
    {$ENDIF}
    {$IFDEF USE_FLRE}
    extractions := nil;
    result := regexpr.ExtractAll(input, extractions,1,1);
    if (not result) or (length(extractions) = 0) then matches := nil
    else matches := extractions[0];
    {$ENDIF}
  except
    on e: EWrappedRegExpr do raise EXQEvaluationException.Create('FORX0002', e.Message);
  end;
end;

procedure wregexprFree(wregexp: TWrappedRegExpr);
begin
  {$ifndef USE_FLRE_WITH_CACHE}
  wregexp.Free;
  {$else}
  ignore(wregexp);
  {$endif}
end;



{$IFDEF USE_FLRE}
type TReplaceCallback = class
  repin: string;
  parsed: boolean;
  repwith: array of record
    literal: string;
    capture: integer;
  end;
  constructor create(rep: string; noescape: boolean);
  function callback(const Input:PFLRERawByteChar;const Captures:TFLRECaptures):TFLRERawByteString;
end;


constructor TReplaceCallback.create(rep: string; noescape: boolean);
begin
  if noescape then begin
    SetLength(repwith, 1);
    repwith[0].literal := rep;
    repwith[0].capture := -1;
  end else repin := rep;
end;

function TReplaceCallback.callback(const Input: PFLRERawByteChar; const Captures: TFLRECaptures): TFLRERawByteString;

var pos: integer;
  procedure abort;
  begin
    raise EXQEvaluationException.create('FORX0004', 'Invalid replacement: '+repin+' after ' + copy(repin, 1, pos));
  end;
var
  temp: RawByteString;
  index: Integer;
  reslen: Integer;
  i: Integer;
begin
  if not parsed then begin
      pos := 1;
      temp := '';
      while pos <= length(repin) do begin
        case repin[pos] of
          '$': begin
            if temp <> '' then begin
              SetLength(repwith, length(repwith) + 1);
              repwith[high(repwith)].literal := temp;
              repwith[high(repwith)].capture := -1;
              temp := '';
            end;
            inc(pos);
            if (pos > length(repin)) or not (repin[pos] in ['0'..'9']) then abort;
            index := ord(repin[pos]) - ord('0');
            inc(pos);
            while (pos <= length(repin)) and (repin[pos] in ['0'..'9']) and (index * 10 + ord(repin[pos]) - ord('0') < length(Captures) ) do begin
              index := index * 10 + ord(repin[pos]) - ord('0');
              inc(pos);
            end;
            dec(pos);
            SetLength(repwith, length(repwith) + 1);
            repwith[high(repwith)].capture := index;
          end;
          '\': begin
            inc(pos);
            if pos > length(repin) then abort;
            case repin[pos] of
              '\', '$': temp += repin[pos];
              else abort;
            end;
          end;
          else temp += repin[pos];
        end;
        inc(pos);
      end;
    if temp <> '' then begin
      SetLength(repwith, length(repwith) + 1);
      repwith[high(repwith)].literal := temp;
      repwith[high(repwith)].capture := -1;
      temp := '';
    end;
    parsed := true;
  end;

  result := '';
  reslen := 0;
  for i := 0 to high(repwith) do begin
    if repwith[i].capture < 0 then strAddFast(result, reslen, repwith[i].literal)
    else if (repwith[i].capture <= high(Captures)) and (Captures[repwith[i].capture].Length > 0) then begin
      SetLength(temp, Captures[repwith[i].capture].Length);
      move((input + Captures[repwith[i].capture].Start)^, temp[1], Captures[repwith[i].capture].Length);
      strAddFast(result, reslen, temp);
    end;
  end;
  if reslen <> length(result) then SetLength(result, reslen);
end;

{$ENDIF}

function xqFunctionReplace(const args: TXQVArray): IXQValue;
var
 regEx: TWrappedRegExpr;
 noescape: Boolean;
 {$IFDEF USE_FLRE}replacer: TReplaceCallback;{$ENDIF}
begin
  requiredArgCount(args, 3,4);
  {$IFDEF USE_FLRE}replacer := nil;{$ENDIF}
  regEx:=wregexprParse(args, 3, false, @noescape);
  try
    try
    {$IFDEF USE_SOROKINS_REGEX}
    result := xqvalue(regEx.Replace(args[0].toString, args[2].toString, not noescape));
    {$ENDIF}
    {$IFDEF USE_FLRE}
    replacer := TReplaceCallback.create(args[2].toString, noescape);
    result := xqvalue(regEx.UTF8ReplaceCallback(args[0].toString, @replacer.callback));
    {$ENDIF}
    except
      on e: EWrappedRegExpr do raise EXQEvaluationException.Create('FORX0002', e.Message);
    end;

  finally
    {$IFDEF USE_FLRE}replacer.Free;{$ENDIF}
    wregexprFree(regEx);
  end;
end;


function xqFunctionMatches(const args: TXQVArray): IXQValue;
var
 regEx: TWrappedRegExpr;
begin
  requiredArgCount(args, 2,3);
  regEx:=wregexprParse(args, 2, true);
  try
    result := xqvalue(wregexprMatches(regEx, args[0].toString))
  finally
    wregexprFree(regEx);
  end;
end;

function xqFunctionTokenize(const args: TXQVArray): IXQValue;
var
  regEx: TWrappedRegExpr;
  input: String;
  {$IFDEF USE_SOROKINS_REGEX}
  lastMatchEnd: Integer;
  {$ENDIF}
  {$IFDEF USE_FLRE}
  i: Integer;
  captures: TFLREMultiCaptures;
  list: TXQVList;
  {$ENDIF}
begin
  requiredArgCount(args, 2, 3);
  input := args[0].toString;
  if input = '' then
    exit(xqvalue);

  regex := wregexprParse(args, 2, false);
  try
    try
      {$IFDEF USE_SOROKINS_REGEX}
      result := nil;
      if regEx.Exec(input) then begin
        lastMatchEnd := 1;
        repeat
          xqvalueSeqAddMove(result, xqvalue(copy(input, lastMatchEnd, regEx.MatchPos[0] - lastMatchEnd)));
          lastMatchEnd := regex.MatchPos[0] + regex.MatchLen[0];
        until not regEx.ExecNext;
        xqvalueSeqAddMove(result, xqvalue(strCopyFrom(input, lastMatchEnd)));
      end else xqvalueSeqAddMove(result, xqvalue(input));
      {$ENDIF}
      {$IFDEF USE_FLRE}
      captures := nil;
      regEx.UTF8MatchAll(input, captures);
      if length(captures) = 0 then exit(xqvalue(input));
      list := TXQVList.create(length(captures)+1);
      list.add(xqvalue(copy(input, 1, captures[0][0].Start - 1)));
      for i := 0 to high(captures) - 1 do
        list.add(xqvalue(copy(input, captures[i][0].Start + captures[i][0].Length, captures[i+1][0].Start - captures[i][0].Start - captures[i][0].Length)));
      list.add(xqvalue(strCopyFrom(input, captures[high(captures)][0].Start + captures[high(captures)][0].Length)));
      result := xqvalueSeqSqueezed(list);
      {$ENDIF}
    except
      on e: EWrappedRegExpr do raise EXQEvaluationException.Create('FORX0002', e.Message);
    end;
  finally
    wregexprFree(regex);
  end;
end;

function xqFunctionAnalyze_String(const context: TXQEvaluationContext; const args: TXQVArray): IXQValue;
var
  regEx: TWrappedRegExpr;
  input: String;
  {$IFDEF USE_SOROKINS_REGEX}

  {$ENDIF}
  {$IFDEF USE_FLRE}
  i: Integer;
  captures: TFLREMultiCaptures;
  {$ENDIF}

  curPos: integer; //handled, excluding curPos
  tempStr: string;
  pendingMatches: array of integer;
  pendingMatchesLen: integer;
  node: TTreeNode;
  j: Integer;

  procedure closeMatches(till: integer; minLength: integer); //till including
  var
    p: LongInt;
  begin
    while (pendingMatchesLen > minLength) and (pendingMatches[pendingMatchesLen - 1] <= till) do begin
      p := pendingMatches[pendingMatchesLen - 1];
      tempStr += xmlStrEscape(copy(input, curPos, p - curPos)) + ifthen(pendingMatchesLen > 1, '</group>', '</match>');
      curPos := p;
      pendingMatchesLen -= 1;
    end;
  end;

  procedure addMatch(id, from, len: integer);
  begin
    if id = 0 then begin
      closeMatches(from, 0);
      if curPos < from then tempStr += '<non-match>' + xmlStrEscape(copy(input, curPos, from - curPos)) + '</non-match>';
      tempStr += '<match>';
    end else begin
      closeMatches(from, 1);
      tempStr += xmlStrEscape(copy(input, curPos, from - curPos)) + '<group nr="'+IntToStr(id)+'">';
    end;
    curPos := from;
    arrayAddFast(pendingMatches, pendingMatchesLen, from + len);
  end;

begin
  requiredArgCount(args, 2, 3);
  input := args[0].toString;
  pendingMatchesLen := 0;
  curPos := 1;
  if input <> '' then begin
    regex := wregexprParse(args, 2, false);
    try
      try
        {$IFDEF USE_SOROKINS_REGEX}
        raise EXQEvaluationException.Create('FORX0002', 'analyze-string requires FLRE ');
        {$ENDIF}
        {$IFDEF USE_FLRE}
        captures := nil;
        regEx.UTF8MatchAll(input, captures);
        for i := 0 to high(captures) do
          for j := 0 to high(captures[i]) do
            addMatch(j, captures[i][j].Start, captures[i][j].Length);
        closeMatches(length(input) + 1, 0);
        if curPos <= length(input) then tempStr += '<non-match>' + xmlStrEscape(strCopyFrom(input, curPos)) + '</non-match>';
        {$ENDIF}
      except
        on e: EWrappedRegExpr do raise EXQEvaluationException.Create('FORX0002', e.Message);
      end;
    finally
      wregexprFree(regex);
    end;
  end else tempStr := '';
  tempStr := '<analyze-string-result xmlns="http://www.w3.org/2005/xpath-functions">' + tempStr + '</analyze-string-result>';


  node := context.parseDoc(tempStr, '', 'text/xml');
  if node = nil then raise EXQEvaluationException.Create('FODC0002', 'Failed to parse document: '+tempStr);

  Result := xqvalue(node.getFirstChild());
end;


function xqFunctionExtract(const args: TXQVArray): IXQValue;
var
 regEx: TWrappedRegExpr;
 matches: array of integer;
 all: Boolean;
 i: Integer;
 input: string;
 {$IFDEF USE_FLRE}
 captures: TFLREMultiCaptures;
 j: Integer;
 {$ENDIF}
begin
  requiredArgCount(args, 2,4);
  input := args[0].toString;
  regEx := wregexprParse(args, 3, true, nil, @all);
  //debugLogMatch
  try
    if length(args) < 3 then begin
      SetLength(matches, 1);
      matches[0] := 0;
    end else begin
      SetLength(matches, args[2].getSequenceCount);
      for i := 0 to high(matches) do matches[i] := args[2].get(i+1).toInt64;
    end;
    result := nil;
    {$IFDEF USE_SOROKINS_REGEX}
    if regEx.Exec(input) then
      repeat
        for i := 0 to high(matches) do
          xqvalueSeqAddMove(result, xqvalue(regEx.Match[matches[i]]));
      until not all or not regEx.ExecNext;
    {$ENDIF}
    {$IFDEF USE_FLRE}
    captures := nil;
    if not all then regex.UTF8MatchAll(input, captures, 1, 1)
    else regex.UTF8MatchAll(input, captures);
    for i := 0 to high(captures) do
      for j := 0 to high(matches) do
        if (matches[j] <= high(captures[i])) then xqvalueSeqAddMove(result, xqvalue(copy(input, captures[i][matches[j]].Start, captures[i][matches[j]].Length)))
        else xqvalueSeqAddMove(result, xqvalue(''));
    {$ENDIF}
    if result = nil then
      if all or (length(matches) = 0) then result := xqvalue()
      else begin
        for i := 0 to high(matches) do
          xqvalueSeqAddMove(result, xqvalue(''));
      end;
  finally
    wregexprFree(regEx)
  end;
end;

{$IFDEF USE_FLRE_WITH_CACHE}

//taken from FLRE:
procedure freeCache;
var
  Index: Integer;
begin
  for Index:=0 to flreCacheList.Count-1 do begin
    TFLRE(flreCacheList[Index]).Free;
   end;
   flreCacheList.Free;
   flreCache.Free;
end;

initialization
  flreCache := TFLRECacheHashMap.Create;
  flreCacheList := TFPList.Create;
  InitCriticalSection(flreCacheLock);

finalization
  freeCache;
  DoneCriticalsection(flreCacheLock);
{$ENDIF}

end.

