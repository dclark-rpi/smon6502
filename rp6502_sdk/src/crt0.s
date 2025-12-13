; Copyright (c) 2023 Rumbledethumps
;
; SPDX-License-Identifier: BSD-3-Clause
; SPDX-License-Identifier: Unlicense

; Boilerplate crt0.s

.export   _init, _exit
.import   _main

.export   __STARTUP__ : absolute = 1
.import   __RAM_START__, __RAM_SIZE__

.import    copydata, zerobss, initlib, donelib

.include  "rp6502.inc"
.include  "zeropage.inc"

; Essential 6502 startup the CPU doesn't do
.segment  "STARTUP"
_init:
    LDX #$FF
    TXS
    CLD

; Set cc65 argument stack pointer
    LDA #<(__RAM_START__ + __RAM_SIZE__)
    STA sp
    LDA #>(__RAM_START__ + __RAM_SIZE__)
    STA sp+1

; Initialize memory storage
    JSR zerobss   ; Clear BSS segment
    JSR copydata  ; Initialize DATA segment
    JSR initlib   ; Run constructors

; Call main()
    JSR _main

; Back from main() also the _exit entry
; Stack the exit value in case destructors call OS
_exit:
    PHX
    PHA
    JSR donelib  ; Run destructors
    PLA
    STA RIA_A
    PLX
    STX RIA_X
    LDA #$FF     ; exit()
    STA RIA_OP
    BRK
