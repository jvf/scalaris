@echo off
:: set path to erlang installation

SETLOCAL ENABLEDELAYEDEXPANSION

set ERL_R16B03=5.10.4
set ERL_R16B02=5.10.3
set ERL_R16B01=5.10.2
set ERL_R16B=5.10.1
set ERL_R15B03_1=5.9.3.1
set ERL_R15B03=5.9.3
set ERL_R15B02=5.9.2
set ERL_R15B01=5.9.1
set ERL_R15B=5.9
set ERL_R14B04=5.8.5
set ERL_R14B03=5.8.4
set ERL_R14B02=5.8.3
set ERL_R14B01=5.8.2
set ERL_R14B=5.8.1
set ERL_R14A=5.8
set ERL_R13B04=5.7.5
set ERL_R13B03=5.7.4
set ERL_R13B02=5.7.3
set ERL_R13B01=5.7.2
set ERL_ALL=%ERL_R16B03% %ERL_R16B02% %ERL_R16B01% %ERL_R16B% %ERL_R15B03_1% %ERL_R15B03% %ERL_R15B02% %ERL_R15B01% %ERL_R15B% %ERL_R14B04% %ERL_R14B03% %ERL_R14B02% %ERL_R14B01% %ERL_R14B% %ERL_R14A% %ERL_R13B04% %ERL_R13B03% %ERL_R13B02% %ERL_R13B01%
if not defined ERLANG_HOME (
    FOR %%c in (%ERL_ALL%) DO (
        FOR %%p in ("%ProgramFiles%\erl%%c" "%ProgramFiles(x86)%\erl%%c") DO (
            set FULL_PATH=%%p
            if exist !FULL_PATH! (
                set ERLANG_HOME=%%p
                goto found
            )
        )
    )
)

:found

echo ERLANG_HOME=%ERLANG_HOME%

ENDLOCAL & set ERLANG_HOME=%ERLANG_HOME%
