;;; The SMON machine language monitor was originally published
;;; in the November/December/January 1984/85 issues of German magazine "64er":
;;; https://archive.org/details/64er_1984_11/page/n59/mode/2up
;;; https://archive.org/details/64er_1984_12/page/n59/mode/2up
;;; https://archive.org/details/64er_1985_01/page/n68/mode/2up
;;; https://archive.org/details/64er_1985_02/page/72/mode/2up
;;; SMON was written for the Commodore 64 by Norfried Mann and Dietrich Weineck
;;;
;;; For an English description of SMON capabilities see: 
;;;     https://www.c64-wiki.com/wiki/SMON
;;; The following original SMON commands are NOT included in this version:
;;;   B (BASIC data), L (disk load), S (disk save), P (printer), I (set I/O device)
;;; The following commands were added in this version:
;;;   H  - print help screen
;;;   L  - load Intel HEX data through terminal
;;;   MS - check and print memory (RAM) size
;;;   MT xxxx yyyy nn - test memory (RAM) xxxx-yyyy nn times (default 1)
;;; 
;;; This code is an adaptation of SMON to a minimal 6502 system by David Hansel (2023).
;;; Minimum system requirements:
;;;   - MOS 6502 CPU
;;;   - MOS 6522 VIA (necessary only if "trace" functions are used)
;;;     The VIA interrupt output must be attached to the 6502 IRQ input
;;;   - 8K of ROM at address E000-F000 (for SMON)
;;;   - 4K of RAM at address 0000-1000
;;;   - UART for communication. As presented here, a MC6850 UART
;;;     at address $8200 is expected. However, this can easily
;;;     be adapted by modifying the code in file "uart.asm"
;;;
;;; This code is based on the following SMON disassembly found at:
;;; https://github.com/cbmuser/smon-reassembly
;;; https://github.com/LeshanDaFo/SMON-RelocatableSourceCode

 .include "config.asm"        

;; zero-page addresses

ADRBUF      := $A4                            ; Address buffer $A4 to $A9 to store three memory locations
FLAG        := $AA                            ; Universal flag
ADRCODE     := $AB                            ; Addressing code for assembler/disassembler
COMMAND     := $AC                            ; SMON instruction code
BEFCODE     := $AD                            ; Instruction code for assembler/disassembler.
LOPER       := $AE                            ; Low operand for assembler/disassembler.
HOPER       := $AF                            ; High operand for assembler/disassembler.
NUMCMDS     := $B1                            ; Hex number of SMON commands in table
BEFLEN      := $B6                            ; Instruction length for assembler/disassembler.
PCL         := $FB                            ; SMON program counter (low byte)
PCH         := $FC                            ; SMON program counter (high byte)
ECL         := $FD                            ; End address for SMON command (low byte)
ECH         := $FE                            ; End address for SMON command (high byte)

;; Outside the zero page, SMON uses the following areas:

;; Processor registers temporary storage:
PCHSAVE     := $02A8                          ; Program Counter (high byte)
PCLSAVE     := $02A9                          ; Program Counter (low byte)
SRSAVE      := $02AA                          ; Processor Status Flag Register
AKSAVE      := $02AB                          ; Accumulator
XRSAVE      := $02AC                          ; Index Register X
YRSAVE      := $02AD                          ; Index Register Y
SPSAVE      := $02AE                          ; Stack Pointer

KBDBUF      := $0277                          ; Buffer for keyboard commands
IONO        := $02B0                          ; Device-Number
MEM         := $02B1                          ; Buffer from $02B1 to $02B7
TRACEBUF    := $02B8                          ; Buffer for trace mode from $02B8 to $02BF   

INTOUT      := $BDCD                          ; Output Positive Integer in A/X
INTOUT1     := $BDD1                          ; Output Positive Integer in A/X

IRQ_LO      := $0314                          ; Vector: Hardware IRQ Interrupt Address Lo
IRQ_HI      := $0315                          ; Vector: Hardware IRQ Interrupt Address Hi
BRK_LO      := $0316                          ; Vector: BRK Lo
BRK_HI      := $0317                          ; Vector: BRK Hi
LOADVECT    := $0330                          ; Vector: Kernel LOAD
SAVEVECT    := $0332                          ; Vector: Kernel SAVE

;; JMPTABLE starts at kernel address $FF81
CHRIN       := JMPTABLE+(3*$1A) ; $FFCF       ; Kernal input routine
CHROUT      := JMPTABLE+(3*$1B) ; $FFD2       ; Kernal output routine
STOPKEY     := JMPTABLE+(3*$20) ; $FFE1       ; Kernal test STOP routine
GETIN       := JMPTABLE+(3*$21) ; $FFE4       ; Kernal get input routine

;; ASCII-Table control codes and characters
CR          := $0D                            ; carriage return
SP          := $20                            ; space
EXCL        := $21                            ; exclamation mark      !
DOLLAR      := $24                            ; dollar                $
APOS        := $27                            ; single quote or tick  '
LPAREN      := $28                            ; open bracket          (
RPAREN      := $29                            ; close bracket         )
AST         := $2A                            ; asterisk              *
PLUS        := $2B                            ; plus                  +
COMMA       := $2C                            ; comma                 ,
MINUS       := $2D                            ; minus or hyphen       -
PERIOD      := $2E                            ; period or dot         .
COLON       := $3A                            ; colon                 :
SEMI        := $3B                            ; semicolon             ;
QUEST       := $3F                            ; question mark         ?

            .org    $E000

            jsr     RESET                     ; kernel reset vector, resets processor registers 
                                              ; and clears line buffer

ENTRY:      lda     #<BREAK                   ; set break-vector to program start
            sta     BRK_LO
            lda     #>BREAK
            sta     BRK_HI
            brk
            nop

;; help message
HLPMSG:     .byte   "A xxxx - Assemble starting at x (end assembly with 'f', use Mdd for label)",0
            .byte   "C xxxx yyyy zzzz aaaa bbbb - Convert (execute V followed by W)",0
            .byte   "D xxxx (yyyy) - Disassemble from xxxx (to yyyy)",0
            .byte   "F aa bb cc ..., xxxx yyyy - Find byte sequence a b c in x-y",0
            .byte   "FA aaaa, xxxx yyyy - Find absolute address used in opcode",0
            .byte   "FR aaaa, xxxx yyyy - Find relative address used in opcode",0
            .byte   "FT xxxx yyyy - Find table (non-opcode bytes) in x-y",0
            .byte   "FZ aa, xxxx yyyy - Find zero-page address used in opcode",0
            .byte   "FI aa, xxxx yyyy - Find immediate argument used in opcode",0
            .byte   "G (xxxx) - Run from xxxx (omit for current Program Counter)",0
            .byte   "K xxxx (yyyy) - Dump memory from xxxx (to yyyy) as ASCII",0
            .byte   "L - Load Intel HEX data from terminal",0
            .byte   "M xxxx (yyyy) - Dump memory from xxxx (to yyyy) as HEX",0
            .byte   "MS - Check and print memory size",0
            .byte   "MT xxxx yyyy (nn) - Test memory xxxx yyyyy (repeat n times)",0
            .byte   "O xxxx yyyy (aa) - Fill memory xxxx yyyy with aa (omit aa to zero erase)",0
            .byte   "R - Display Processor Registers",0
            .if     VIA > 0
              .byte   "TW xxxx - Trace walk (single step)",0
              .byte   "TB xxxx nn - Trace break (set break point at x, stop when hit n times)",0
              .byte   "TQ xxxx - Trace quick (run to break point)",0
              .byte   "TS xxxx - Trace stop (run to xxxx)",0
            .endif
            .byte   "V xxxx yyyy zzzz aaaa bbbb - Within a-b, convert addresses referencing x-y to z",0
            .byte   "W xxxx yyyy zzzz - Copy memory xxxx yyyy to z",0
            .byte   "X - Exit SMON",0
            .byte   ";xxxx xx xx xx xx xx bbbbbbbb - Edit 6502 Registers- PC SR AC XR YR SP NV-BDIZC",0
            .byte   "=xxxx yyyy - compare memory starting at x to memory starting at y",0
            .byte   ":xxxx aa aa - change memory in HEX starting at x with one or more bytes",0
            .byte   "#ddddd - convert DEC to HEX and BIN, max = #65535 (16Bit Num)",0
            .byte   "$aa(aa) - convert 2-digit or 4-digit HEX to DEC and BIN",0
            .byte   "%bbbbbbbb - convert BIN to DEC and HEX (b must be a 1 or 0)",0
            .byte   "?aaaa+aaaa - Hexadecimal addition (you must enter two, 4-digit hex numbers)",0
            .byte   "?aaaa-aaaa - Hexadecimal subtraction (you must enter two, 4-digit hex numbers)",0
            .byte   0
        
;; commands
CMDTBL:     .byte   "'#$%,:;=?ACDFGHKLMORTVWX"
CMDTBLE:    .byte   $00,$00,$00,$00,$00                        ; . .. ..

;; command entry point addresses
CMDS:       .byte   <(TICK-1),>(TICK-1)             ; '
            .byte   <(BEFDEC-1),>(BEFDEC-1)         ; #
            .byte   <(BEFHEX-1),>(BEFHEX-1)         ; $
            .byte   <(BEFBIN-1),>(BEFBIN-1)         ; %
            .byte   <(COMMACMD-1),>(COMMACMD-1)     ; ,
            .byte   <(EDITMEM-1),>(EDITMEM-1)       ; :     
            .byte   <(EDITREG-1),>(EDITREG-1)       ; ; 
            .byte   <(EQUALS-1),>(EQUALS-1)         ; =
            .byte   <(ADDSUB-1),>(ADDSUB-1)         ; ?
            .byte   <(ASSEMBLER-1),>(ASSEMBLER-1)   ; A
            .byte   <(CONVERT-1),>(CONVERT-1)       ; C
            .byte   <(DISASS-1),>(DISASS-1)         ; D
            .byte   <(FIND-1),>(FIND-1)             ; F
            .byte   <(GO-1),>(GO-1)                 ; G
            .byte   <(HELP-1),>(HELP-1)             ; H
            .byte   <(KONTROLLE-1),>(KONTROLLE-1)   ; K
            .byte   <(LOAD-1),>(LOAD-1)             ; L
            .byte   <(MEMDUMP-1),>(MEMDUMP-1)       ; M
            .byte   <(OCCUPY-1),>(OCCUPY-1)         ; O
            .byte   <(REGISTER-1),>(REGISTER-1)     ; R
            .byte   <(TRACE-1),>(TRACE-1)           ; T
            .byte   <(MOVE-1),>(MOVE-1)             ; V
            .byte   <(WRITE-1),>(WRITE-1)           ; W
            .byte   <(EXIT-1),>(EXIT-1)             ; X

;; output line start characters
CMDTAB:     .byte   "':;,()!"
            .byte   <(ILOPC-1),>(ILOPC-1)           ; activate the illegal opcodes
            .byte   $00,$00
            .byte   $00,$00,$00
        
OFFSET:     .byte   $FF,$FF,$01,$00

;; sub-commands for "find" (F)
FSCMD:      .byte   "AZIRT"

;; "find" sub-command
FSFLAG:     .byte   $80,$20,$40,$10,$00

;; "find" sub-command data length (2=word,1=byte,0=none)
FSFLAG1:    .byte   $02,$01,$01,$02,$00      

REGHDR:     .byte   $0D,$0D,"  PC  SR AC XR YR SP  NV-BDIZC"
LC0AC:      .byte   $00,$02,$04
LC0AF:      .byte   $01,$2C,$00
LC0B2:      .byte   $2C,$59,$29
LC0B5:      .byte   $58,$9D,$1F,$FF,$1C,$1C,$1F,$1F
            .byte   $1F,$1C,$DF,$1C,$1F,$DF,$FF,$FF
            .byte   $03
LC0C6:      .byte   $1F,$80,$09,$20,$0C,$04,$10,$01
            .byte   $11,$14,$96,$1C,$19,$94,$BE,$6C
            .byte   $03,$13
LC0D8:      .byte   $01,$02,$02,$03,$03,$02,$02,$02
            .byte   $02,$02,$02,$03,$03,$02,$03,$03
            .byte   $03,$02
LC0EA:      .byte   $00,$40,$40,$80,$80,$20,$10,$25
            .byte   $26,$21,$22,$81,$82,$21,$82,$84
            .byte   $08
LC0FB:      .byte   $08,$E7,$E7,$E7,$E7,$E3,$E3,$E3
            .byte   $E3,$E3,$E3,$E3,$E3,$E3,$E3,$E7
            .byte   $A7,$E7,$E7,$F3,$F3,$F7
LC111:      .byte   $DF
        
;; 6502 opcodes (in same order as mnemonics below)
OPC:        .byte   $26,$46,$06,$66,$41,$81,$E1,$01
            .byte   $A0,$A2,$A1,$C1,$21,$61,$84,$86
            .byte   $E6,$C6,$E0,$C0,$24,$4C,$20,$90
            .byte   $B0,$F0,$30,$D0,$10,$50,$70,$78
            .byte   $00,$18,$D8,$58,$B8,$CA,$88,$E8
OPC1:       .byte   $C8,$EA,$48,$08,$68,$28,$40,$60         
            .byte   $AA,$A8,$BA,$8A,$9A,$98,$38,$F8
OPC2:       .byte   $89,$9C,$9E
OPC3:       .byte   $B2,$2A,$4A,$0A,$6A,$4F,$23,$93
            .byte   $B3,$F3,$33,$D3,$13,$53,$73

;; first, second and third characters of opcode mnemonics
OPMN1:      .byte   "RLARESSOLLLCAASSIDCCBJJBBBBBBBBSBCCCCDDIINPPPPRRTTTTTTSS"
OPMN2:      .byte   "OSSOOTBRDDDMNDTTNEPPIMSCCEMNPVVERLLLLEENNOHHLLTTAASXXYEE"
OPMN3:      .byte   "LRLRRACAYXAPDCYXCCXYTPRCSQIELCSIKCDIVXYXYPAPAPISXYXASACD"
        
LC204:      .byte   $08,$84,$81,$22,$21,$26,$20,$80
LC20C:      .byte   $03,$20,$1C,$14,$14,$10,$04,$0C

;; 6502 illegal opcodes (in same order as mnemonics below)
ILOPC:      .byte   $2B,$4B,$6B,$8B,$9B,$AB,$BB,$CB
            .byte   $EB,$89,$93,$9F,$0B,$9C,$9E

;; first, second and third characters of illegal opcode mnemonics
ILOPMN1:     .byte   "NSRSRSLDIC"
ILOPMN2:     .byte   "OLLRRAACSR"
ILOPMN3:     .byte   "POAEAXXPCA"

LCE36:       .byte   $25,$26,$20,$21,$82,$80,$81
             .byte   $22,$21,$82
LCE40:       .byte   $81,$03,$13,$07,$17,$1B,$0F,$1F
             .byte   $97,$D7,$BF
LCE4B:       .byte   $DF,$02,$02,$02,$02,$03,$03,$03
             .byte   $02,$02,$03,$03

;; SMON START
BREAK:      cld
            ldx     #$05
BREAK2:     pla
            sta     PCHSAVE,x                 ; store stack pointer
            dex
            bpl     BREAK2
            lda     PCLSAVE                   ; load program counter (low byte) into accumulator
            bne     BREAK3
            dec     PCHSAVE                   ; decrement program counter stored (high byte)
BREAK3:     dec     PCLSAVE                   ; decrement program counter stored (low byte)  
            tsx
            stx     SPSAVE                    ; store stack pointer
            lda     #'R'                      ; execute 'R' command
            jmp     CMDSTORE                  ; jump to main loop
        
GETSTART:   jsr     GETRETURN                 ; check for return
            beq     GETSTRTS
GETSTART1:  jsr     GETADR                    ; get memory address from commandline
            sta     PCLSAVE                   ; store program counter (low byte)
            lda     PCH                       ; load program counter (high byte)
            sta     PCHSAVE                   ; store program counter (high byte)
GETSTRTS:   rts
     
;; get 3 memory address words into $A4-$A9
GET3ADR:    ldx     #ADRBUF                   ; load address buffer in $A4
            jsr     GETADRX
            jsr     GETADRX
            bne     GETADRX

;; get start (FB/FC) and end (FD/FE) address from commandline
;; end address is optional, defaults to $FFFE
GETADRSE:   jsr     GETADR                    ; get memory address from commandline
            lda     #ECH                      
            sta     ECL                       ; store end address (low byte)
            lda     #$FF                      ; mask
            sta     ECH                       ; store end address (high byte)
            jsr     GETRETURN                 ; is there more commandline input?
            bne     GETADRX                   ; yes, get another memory address
            sta     KBDBUF                    ; put NUL into keyboard buffer
            inc     $C6
            rts

;; get two words from commandline, store in $FB/$FC and $FD/$FE
GETDW:      jsr     GETADR                    ; get memory address from commandline
            .byte   $2C                       ; skip next (2-byte) opcode

;; get memory address from commandline, store in $FB/$FC
GETADR:     ldx     #PCL
        
;; get word from commandline, store in (X)/(X+1)
GETADRX:    jsr     GETBYT
            sta     $01,x
            jsr     GETBYT1
            sta     $00,x
            inx
            inx
            rts

;; get byte from commandline, ignore leading " " and ","
GETBYT:     jsr     GETCHRET                  ; get next character byte until a carriage return is reached
            cmp     #SP                       ; is character byte a space " "
            beq     GETBYT
            cmp     #COMMA                    ; is character byte a ","
            beq     GETBYT
            bne     ASCHEX                    ; convert to 0-15

;; get byte from commandline, return in A
GETBYT1:    jsr     GETCHRET                  ; get next character until a carriage return
ASCHEX:     jsr     ASCHEX1                   ; convert to 0-15
            asl
            asl
            asl
            asl
            sta     $B4
            jsr     GETCHRET                  ; get next character until a carriage return
            jsr     ASCHEX1                   ; convert to 0-15
            ora     $B4
            rts

;; convert character in A from ASCII HEX to 0-15
ASCHEX1:    cmp     #COLON                    ; is character a ":"
            bcc     ASCHEX2
            adc     #$08
ASCHEX2:    and     #$0F
            rts

;; skip spaces from commandline
SKIPSPACE:  jsr     GETCHRET                  ; get next character until a carriage return
            cmp     #SP                       ; is character byte a space " "
            beq     SKIPSPACE
            dec     $D3
            rts

;; peek whether next character on commandline is CR (Z set if so)
GETRETURN:  jsr     CHRIN
            dec     $D3
            cmp     #$0D
GETBRTS:    rts

;; convert character in A to uppercase
UCASE:      cmp     #'a'
            bcc     UCASE1
            cmp     #'z'+1
            bcs     UCASE1
            and     #$DF
UCASE1:     rts
        
;; get next character from commandline, error if CR (end of line)
GETCHRET:   jsr     CHRIN
            jsr     UCASE
GETCL1:     cmp     #$0D
            bne     GETBRTS

;; invalid input
ERROR:      lda     #QUEST                    ; print "?"
            jsr     CHROUT

;; main loop
EXECUTE:    ldx     SPSAVE                    ; restore stack pointer                
            txs
            ldx     #$00                      ; clear keyboard buffer
            stx     $C6
            lda     $D3                       ; get cursor column
            beq     SKIPCR                    ; jump if zero
            jsr     RETURN                    ; output ASCII carriage return (CR)
SKIPCR:     lda     ($D1,x)                   ; get first character of next line
            ldx     #$06                      ; compare to known line start characters: ':;,()!
CHKCMD:     cmp     CMDTAB,x                  ; check for line start command
            beq     EXEC1                     ; if found, execute command
            dex
            bpl     CHKCMD
            lda     #PERIOD                   ; print prompt (".")
            jsr     CHROUT
EXEC1:      jsr     GETCHRET                  ; get next character until a carriage return
            cmp     #PERIOD                   ; is character "."
            beq     EXEC1                     ; ignore leading "."
            jmp     CMDSTORE                  ; check entered command is valid and execute
NEXTCMD:    jmp     ERROR
        
;; find user command in A
CMDSTORE:   sta     COMMAND                   ; store A in command 
            and     #$7F                      ; delete bit 7
            ldx     #CMDTBLE-CMDTBL           ; amount of commands
            stx     NUMCMDS                   ; save number of commands into variable
FNDCMD:     cmp     CMDTBL-1,x                ; compare command char
            beq     CMDFOUND                  ; found valid command
            dex                               ; next command char
            bne     FNDCMD                    ; loop until we checked all command chars
            beq     NEXTCMD                   ; no match => error
CMDFOUND:   jsr     CMDEXEC                   ; fetch routine offset
            jmp     EXECUTE                   ; back to main loop, wait for next input

;; execute command specified by index in X
CMDEXEC:    txa                               ; X = X*2+1
            asl
            tax
            inx
            lda     CMDS-2,x                  ; low address 
            pha                               ; on stack
            dex
            lda     CMDS-2,x                  ; high address
            pha                               ; on stack 
            rts                               ; jump to execute command

;; output data word in FB/FC as 4-digit hex
HEXOUT:     lda     PCH                       ; load program counter high byte
            jsr     HEXOUT1                   ; output 2 digit hex address
            lda     PCL                       ; load program counter low byte

;; output data byte in Accumulator as 2-digit HEX
HEXOUT1:    pha                               ; save byte in accumulator
            lsr                               ; shift 4 times to get low nibble
            lsr
            lsr
            lsr
            jsr     HEXOUT2                   ; output one nibble
            pla                               ; restore saved value to accumulator
            and     #$0F                      ; mask low nibble
HEXOUT2:    cmp     #$0A                      ; compare with value
            bcc     HEXOUT3                   ; output as number
            adc     #$06                      ; add 6 for letter
HEXOUT3:    adc     #$30                      ; add $30
            jmp     CHROUT                    ; output converted hex value

;; output CR, followed by character in X
CHARRTN:    lda     #$0D                      ; move pointer to next line
CHAROUT:    jsr     CHROUT
            txa                               ; get value from x
            jmp     CHROUT

;; output two SPACE characters
DBLSPACE:   jsr     SPACE                     ; loop to ouput second space character

;; output SPACE Character
SPACE:      lda     #SP                       ; load accumulator with a space character byte " "
            jmp     CHROUT                    ; output space chcarcter

;; output CR Character
RETURN:     lda     #$0D                      ; ASCII Carriage Return (CR)
            jmp     CHROUT

;; print 0-terminated string pointed to by A/Y
STROUT:     sta     $BB                       ; pointer to address low byte
            sty     $BC                       ; pointer to address high byte
            ldy     #$00                      ; counter
STROUT1:    lda     ($BB),y                   ; get byte from address
            beq     STROUT2                   ; if 0 then end
            jsr     CHROUT
            inc     $BB                       ; increment pointer to low byte address
            bne     STROUT1
            inc     $BC                       ; increment pointer to high byte address
            bne     STROUT1
STROUT2:    rts

;; increment Program Counter(PC) in $FB/$FC
PCINC:      inc     PCL                       ; increase program counter low byte
            bne     PCRTS                     ; if not 0, then finish
            inc     PCH                       ; increase program counter high byte
PCRTS:      rts

;; HELP (H)
HELP:       lda     #<HLPMSG                  ; get help message start addr
            sta     $BB                       ; into $BB/$BC
            lda     #>HLPMSG
            sta     $BC
            ldy     #$00
HLPL1:      lda     #$0D                      ; output CR
            jsr     CHROUT
            jsr     STROUT1                   ; output string until 0
            iny                               ; next byte
            cpy     #20                       ; are we at line 20?
            bne     HLPL2                     ; jump if not
            lda     #SP                       ; load accumulator with a space character byte " "
            sta     KBDBUF                    ; load " " byte into keyboard buffer (to pause output)
            inc     $C6
HLPL2:      jsr     KBDKEY                    ; check for PAUSE,STOP from commandline
            lda     ($BB),y                   ; get first byte of next string
            bne     HLPL1                     ; loop if not 0
            rts
                
;; REGISTER (R)
REGISTER:   ldy     #>REGHDR
            lda     #<REGHDR
            jsr     STROUT
            ldx     #$3B
            jsr     CHARRTN                   ; new line followed by a character from x
            lda     PCHSAVE                   ; load program counter (high byte) into accumulator
            sta     PCH                       ; restore program counter (high byte)
            lda     PCLSAVE                   ; load program counter (low byte) into accumulator
            sta     PCL                       ; restore program counter (low byte)
            jsr     HEXOUT                    ; output as 4 digit hex
            jsr     SPACE                     ; output SPACE character
            ldx     #PCL
REGISTER1:  lda     $01AF,x
            jsr     HEXOUT1
            jsr     SPACE                     ; output SPACE character
            inx
            bne     REGISTER1
            lda     SRSAVE                    ; load processor status flag register into accumulator
            jmp     FLG2BIN                   ; display processor flags as binary string
        
;; EDIT PROCESSOR REGISTERS (;)
EDITREG:    jsr     GETSTART1
            ldx     #PCL
CHNGREG:    jsr     GETCHRET                  ; get next character until a carriage return
            jsr     GETBYT1
            sta     $01AF,x
            inx
            bne     CHNGREG
            jsr     SPACE                     ; output SPACE Character
            lda     SRSAVE,x                  ; load processor status flag register into accumulator
            jmp     FLG2BIN                   ; display processor flags as binary string
FLG2BIN:    sta     FLAG
            lda     #SP                       ; load accumulator with a space character byte " "
            ldy     #$09
STR2BIN:    jsr     CHROUT
            asl     FLAG
            lda     #$30
            adc     #$00
            dey
            bne     STR2BIN
            rts
        
;; RUN PROGRAM - GO (G)
GO:         jsr     GETSTART
            ldx     SPSAVE                    ; load stack pointer
            txs
            ldx     #$FA
GO_LOOP:    lda     $01AE,x
            pha
            inx
            bne     GO_LOOP
            pla
            tay
            pla
            tax
            pla
            rti

;; LOAD INTEL HEX (L)
LOAD:       lda     #13
            jsr     CHROUT
LDNXT:      jsr     UAGETW                    ; get character from UART
            cmp     #SP                       ; is character byte a space " "
            beq     LDNXT                     ; ignore space at beginning of line
            cmp     #13
            beq     LDNXT                     ; ignore CR at beginning of line
            cmp     #10
            beq     LDNXT                     ; ignore LF at beginning of line
            cmp     #27
            beq     LDBRK                     ; stop when receiving BREAK
            cmp     #3
            beq     LDBRK                     ; stop when receiving CTRL-C
            cmp     #':'                      ; expect ":" at beginning of line
            bne     LDEIC
            jsr     LDBYT                     ; get record byte count
            tax
            jsr     LDBYT                     ; get address high byte
            sta     PCH
            jsr     LDBYT                     ; get address low byte
            sta     PCL
            jsr     LDBYT                     ; get record type
            beq     LDDR                      ; jump if data record (record type 0)
            cmp     #1                        ; end-of-file record (record type 1)
            bne     LDERI                     ; neither a data nor eof record => error

;; read Intel HEX end-of-file record
            jsr     LDBYT                     ; get next byte (should be checksum)
            cmp     #$FF                      ; checksum of EOF record is FF
            bne     LDECS                     ; error if not
LDEOF:      rts

;; read Intel HEX data record
LDDR:       clc                               ; prepare checksum
            txa                               ; byte count
            adc     PCL                       ; address low
            clc
            adc     PCH                       ; address high
            sta     ECL                       ; store checksum
            ldy     #0                        ; offset
            inx
LDDR1:      dex                               ; decrement number of bytes
            beq     LDDR2                     ; done if 0
            jsr     LDBYT                     ; get next data byte
            sta     (PCL),y                   ; store data byte
            cmp     (PCL),y                   ; check data byte
            bne     LDEM                      ; memory error if no match
            clc
            adc     ECL                       ; add to checksum
            sta     ECL                       ; store checksum
            iny
            bne     LDDR1
LDDR2:      jsr     LDBYT                     ; get checksum byte
            clc
            adc     ECL                       ; add to computed checkum
            bne     LDECS                     ; if sum is 0 then checksum is ok
            lda     #'+'
            jsr     UAPUTW
            inc     $D3
            cpy     #0                        ; did we have 0 bytes in this record?
            bne     LDNXT                     ; if not then expect another record
            beq     LDEOF                     ; end of file

        
LDBRK:      lda     #'B'                      ; received BREAK (ESC)
            .byte   $2C
LDERI:      lda     #'R'                      ; unknown record identifier error
            .byte   $2C
LDECS:      lda     #'C'                      ; checksum error
            .byte   $2C
LDEIC:      lda     #'I'                      ; input character error
            .byte   $2C
LDEM:       lda     #'M'                      ; memory error
            jsr     CHROUT
LDERR:      jmp     ERROR
        
;; get HEX byte from UART
LDBYT:      jsr     LDNIB                     ; get high nibble
            asl
            asl
            asl
            asl
            sta     $B4
            jsr     LDNIB                     ; get low libble
            ora     $B4                       ; combine
            rts
;; get HEX character from UART, convert to 0-15
LDNIB:      jsr     UAGETW                    ; get character from UART
            jsr     UCASE                     ; convert to uppercase
            cmp     #'0'
            bcc     LDEIC
            cmp     #'F'+1
            bcs     LDEIC
            cmp     #'9'+1
            bcc     LDBYT2
            cmp     #'A'
            bcc     LDEIC
            adc     #$08
LDBYT2:     and     #$0F
            rts
                
;; MEMORY DUMP (M)
MEMDUMP:    jsr     GETCHRET                  ; get next character until a carriage return
            beq     MEMERR                    ; error if CR
            cmp     #'T'                      ; is it 'T'
            bne     MD1                       ; go to memory dump
            jmp     MEMTST
MD1:        cmp     #'S'
            bne     MD2
            jmp     MEMSIZ
MD2:        cmp     #SP                       ; is character byte a space " "
            bne     MEMERR
MD3:        jsr     GETADRSE                  ; get start (FB/FC) and end address (FD/FE)
MEMDUMP1:   ldx     #COLON                    ; load x register with ":"
            jsr     CHARRTN                   ; New line followed by a character from x
            jsr     HEXOUT                    ; print address in FB/FC
            ldy     #80-17
            ldx     #0
MEMDUMP2:   jsr     SPACE                     ; output SPACE Character
            cpy     #80-9
            bne     MEMDUMP3
            jsr     SPACE                     ; output SPACE Character
            iny
MEMDUMP3:   lda     (PCL,x)
            jsr     HEXOUT1                   ; output byte as HEX
            lda     (PCL,x)
            jsr     ASCII                     ; write ASCII char of byte directly to screen
            bne     MEMDUMP2                  ; repeat until end-of-line
            jsr     PREOL                     ; print to end of line
            jsr     CHECKEND                  ; check for PAUSE/STOP or end condition
            bcc     MEMDUMP1                  ; repeat until end
            rts

;; EDIT MEMORY (:)
EDITMEM:    jsr     GETADR                    ; get start address from commandline
            ldy     #80-17
            ldx     #$00
MEMCHAR:    cpy     #80-9
            bne     NEXTCHAR
            iny
NEXTCHAR:   jsr     CHRIN                     ; get next character
            cmp     #SP                       ; is next character byte a space " "
            beq     MEMCHAR                   ; skip space
            cmp     #$0D                      ; is next character a carriage return
            beq     MEMRTS                    ; if a carriage return end
            dec     $D3                       ; go back one input char
            jsr     GETBYT1                   ; get hex byte
            sta     (PCL,x)                   ; store byte
            cmp     (PCL,x)                   ; compare (make sure it's not ROM)
            beq     SKIPERR                   ; if match then skip
MEMERR:     jmp     ERROR                     ; print error
SKIPERR:    jsr     ASCII                     ; write ASCII to screen
            bne     MEMCHAR                   ; repeat until end
            lda     #80-17
            jsr     PRLINE
MEMRTS:     rts

;; OCCUPY (O) - erase memory with a byte of data
OCCUPY:     jsr     GETDW                     ; get address range
            inc     ECL                       ; increment end address to make sure data is written to
                                              ; the full address range
            jsr     CHRIN                     ; get byte from commandline
            jsr     UCASE                     ; change fetched byte to uppercase, if a letter
            cmp     #$0D                      ; compare CR with commandline data byte
            beq     MEM_ZERO                  ; if CR then branch to erase with zero's subroutine
            jsr     GETBYT                    ; get next commandline byte from subroutine
            pha
            jsr     RETURN                    ; output ASCII carriage return (CR)
            pla
OCCUPY1:    ldx     #$00                      ; jmp from erase command
OCCUPY2:    sta     (PCL,x)                   ; this routine does the memory change
            pha
            jsr     CMPEND
            pla
            bcc     OCCUPY2
            rts

;; erase memory with zero byte
MEM_ZERO:   lda     #$00                      ; set accumulator value to zero
            jmp     OCCUPY1                   ; jump to occupy Command
        
;; put character into screen buffer at column Y
;; (make sure it is printable first)
ASCII:      cmp     #$20                      ; is character code byte < 32 decimal
            bcc     ASCII_1                   ; if so, print "."
            cmp     #$7F                      ; is character code byte >= 127 decimal
            bcs     ASCII_1                   ; if so, print "."
            bcc     ASCII_2                   ; print character
ASCII_1:    lda     #PERIOD                   ; load "." into accumulator
ASCII_2:    sta     ($D1),y
            lda     $0286
            sta     ($F3),y
ASCII_3:    jsr     PCINC                     ; increment program counter
            iny
            cpy     #80
            rts
     
;; check stop/pause condition, return with carry set
;; if end address reached
CHECKEND:   jsr     KBDKEY                    ; end-of-line wait handling
            jmp     CMPEND1                   ; check for end address and return

;; increment address in $FB/$FC and check whether end address
;; ($FD/$FE) has been reached, if not, C is clear on return
CMPEND:     jsr     PCINC                     ; increment program counter
        
;; check whether end address has been reached, C is clear if not
CMPEND1:    lda     PCL                       ; load program counter (low byte) into accumulator
            cmp     ECL                       ; compare acculator with end address (low byte)
            lda     PCH                       ; load program counter (high byte) into accumulator
            sbc     ECH                       ; subtract end address (high byte) from accumulator
            rts

;; end-of-line wait handling:
;; - stop if STOP key pressed
;; - wait if any key pressed
;; - if SPACE pressed, immediately stop again after next line
KBDKEY:     jsr     SCANKEY                   ; check for STOP or keypress
            beq     KBDRTS                    ; no key => done
KBDKEY1:    jsr     SCANKEY                   ; check for STOP or keypress
            beq     KBDKEY1                   ; no key => wait
            cmp     #SP                       ; is character byte a space " "
            bne     KBDRTS                    ; no => done
            sta     KBDBUF                    ; put SPACE in keyboard buffer
            inc     $C6                       ; (i.e. advance just one line)
KBDRTS:     rts

;; check for STOP or other keypress
SCANKEY:    jsr     GETIN                     ; get input character (kernal subroutine)
            pha                               ; save char
            jsr     STOPKEY                   ; check stop key
            beq     STOP                      ; jump if pressed
            pla                               ; restore char to A
SCANRTS:    rts
STOP:       jmp     EXECUTE                   ; back to main loop

 
LC4CB:      ldy     #$00
            lda     (PCL),y                   ; get opcode at $FB/FC
            bit     FLAG
            bmi     LC4D5
            bvc     LC4E1
LC4D5:      ldx     #$1F
LC4D7:      cmp     OPC1+2,x
            beq     LC50B
            dex
            cpx     #$15
            bne     LC4D7
LC4E1:      ldx     #$04
LC4E3:      cmp     OPC2-1,x
            beq     LC509
            cmp     OPC3,x
            beq     LC50B
            dex
            bne     LC4E3
            ldx     #$38
LC4F2:      cmp     OPC-1,x
            beq     LC50B
            dex
            cpx     #$16
            bne     LC4F2
LC4FC:      lda     (PCL),y
            and     LC0FB,x
            eor     OPC-1,x
            beq     LC50B
            dex
            bne     LC4FC
LC509:      ldx     #$00
LC50B:      stx     BEFCODE
            txa
            beq     LC51F
            ldx     #$11
LC512:      lda     (PCL),y
            and     LC0B5,x
            eor     LC0C6,x
            beq     LC51F
            dex
            bne     LC512
LC51F:      lda     LC0EA,x
            sta     ADRCODE
            lda     LC0D8,x
            sta     BEFLEN
            jmp     ILOPCM
        
LC52C:      ldy     #$01
            lda     (PCL),y
            tax
            iny
            lda     (PCL),y
            ldy     #$10
            cpy     ADRCODE
            bne     LC541
            jsr     LC54A
            ldy     #$03
            bne     LC543
LC541:      ldy     BEFLEN
LC543:      stx     LOPER
            nop
            sta     HOPER
            nop
            rts
        
LC54A:      ldy     #$01
            lda     (PCL),y
            bpl     LC551
            dey
LC551:      sec
            adc     $FB
            tax
            inx
            beq     LC559
            dey
LC559:      tya
            adc     $FC
LC55C:      rts

        
; DISASSEMBLER (D)
DISASS:     ldx     #$00
            stx     FLAG
            jsr     GETADRSE                  ; get start (FB/FC) and end address (FD/FE)
LC564:      jsr     LC58C
            lda     BEFCODE
            cmp     #$16
            beq     LC576
            cmp     #$30
            beq     LC576
            cmp     #$21
            bne     LC586
            nop
LC576:      jsr     RETURN                    ; output ASCII carriage return (CR)
            ldx     #$23
            lda     #MINUS                    ; load accumulator with minus character byte "-"
LC580:      jsr     CHROUT                    ; output a minus character "-"
            dex
            bne     LC580
LC586:      jsr     CHECKEND
            bcc     LC564
            rts
        
LC58C:      ldx     #COMMA                    ; output NEWLINE followed by ","
            jsr     CHARRTN                   ; New line followed by a character from x
            jsr     HEXOUT                    ; output FB/FC (address)
            jsr     SPACE                     ; output SPACE Character
LC597:      jsr     LC675                     ; erase to end of line
            jsr     LC4CB
            jsr     SPACE                     ; output SPACE Character
LC5A0:      lda     (PCL),y                   ; get data byte
            jsr     HEXOUT1                   ; output byte in A
            jsr     SPACE                     ; output SPACE Character
            iny
            cpy     BEFLEN
            bne     LC5A0
            lda     #$03
            sec
            sbc     BEFLEN
            tax
            beq     SPCOC
LC5B5:      jsr     DBLSPACE                  ; output two SPACE Characters
            jsr     SPACE                     ; output SPACE Character
            dex
            bne     LC5B5
SPCOC:      jmp     ILOPCD                   ; output illegal opcode
            .byte   $D2
            .byte   $FF
            ldy     #$00
            ldx     BEFCODE
LC5C7:      bne     LC5DA
LC5C9:      ldx     #$03
LC5CB:      lda     #$2A
            jsr     CHROUT
            dex
            bne     LC5CB
            bit     FLAG
            bmi     LC55C
            jmp     LC66A
LC5DA:      bit     FLAG
            bvc     LC607
            lda     #$08
            bit     ADRCODE
            beq     LC607
            lda     (PCL),y
            and     #PCH
            sta     BEFCODE
            iny
            lda     (PCL),y
            asl
            tay
            lda     $033C,y
            sta     LOPER
            nop
            iny
            lda     $033C,y
            sta     HOPER
            nop
            jsr     LC6BE
            ldy     BEFLEN
            jsr     LC693
            jsr     LC4CB
LC607:      lda     OPMN1-1,x
            jsr     CHROUT
            lda     OPMN2-1,x
            jsr     CHROUT
            lda     OPMN3-1,x
LC616:      jsr     CHROUT
            lda     #$20
            bit     ADRCODE
            beq     LC622
            jsr     DBLSPACE                  ; output two SPACE characters
LC622:      ldx     #$20
            lda     #$04
            bit     ADRCODE
            beq     LC62C
            ldx     #$28
LC62C:      txa
            jsr     CHROUT
            bit     ADRCODE
            bvc     LC639
            lda     #$23
            jsr     CHROUT
LC639:      jsr     LC52C
            dey
            beq     LC655
            lda     #$08
            bit     ADRCODE
            beq     LC64C
            lda     #$4D
            jsr     CHROUT
            ldy     #$01
LC64C:      lda     BEFCODE,y
            jsr     HEXOUT1
            dey
            bne     LC64C
LC655:      ldy     #$03
LC657:      lda     LC0AC,y
            bit     ADRCODE
            beq     LC667
            lda     LC0AF,y
            ldx     LC0B2,y
            jsr     CHAROUT                   ; output character followed by X
LC667:      dey
            bne     LC657
LC66A:      lda     BEFLEN
LC66C:      jsr     PCINC                     ; increment program counter
            sec
            sbc     #$01
            bne     LC66C
            rts

;; erase screen buffer to end of line
LC675:      ldy     $D3
            lda     #SP                       ; load accumulator with a space character byte " "
LC679:      sta     ($D1),y
            iny
            cpy     #$28
            bcc     LC679
            rts
        
LC681:      cpx     ADRCODE
            bne     LC689
            ora     BEFCODE
            sta     BEFCODE
LC689:      rts

;; copy $AD through $AD+y to ($FB)
LC68A:      lda     BEFCODE,y
            sta     (PCL),y
            cmp     (PCL),y
            bne     LC697
LC693:      dey
            bpl     LC68A
            rts
        
LC697:      pla
            pla
            rts
        
LC69A:      bne     LC6B8
            txa
            ora     ADRCODE
            sta     ADRCODE

;; get first character that is not " $(," (max 4)
LC6A1:      lda     #$04
            sta     $B5
LC6A5:      jsr     CHRIN                     ; get new character byte
            cmp     #SP                       ; is charcter byte a space " "
            beq     LC6B9                     ; 
            cmp     #DOLLAR                   ; is character byte a dollar "$"
            beq     LC6B9
            cmp     #LPAREN                   ; is character byte a open bracket "("
            beq     LC6B9
            cmp     #COMMA                    ; is character byte a comma ","
            beq     LC6B9
            jsr     UCASE                     ; convert ASCII characters to uppercase
LC6B8:      rts

;; character was either " ", "$", "(" or ","
LC6B9:      dec     $B5
            bne     LC6A5                     ; get next character byte
            rts
        
LC6BE:      cpx     #$18
            bmi     LC6D0                     
            lda     LOPER
            nop
            sec
            sbc     #$02
            sec
            sbc     PCL
            sta     LOPER
            nop
            ldy     #$40
LC6D0:      rts

; ASSEMBLER (A)
ASSEMBLER:
            jsr     GETADR                    ; get start address
            sta     ECL
            lda     PCH
            sta     ECH
LC6DA:      jsr     RETURN                    ; output ASCII carriage return (CR)
LC6DD:      jsr     LC6E4                     ; get and assemble line
            bmi     LC6DD
            bpl     LC6DA
        
LC6E4:      lda     #$00
            sta     $D3
            jsr     SPACE                     ; output SPACE Character
            jsr     HEXOUT                    ; output address
            jsr     SPACE                     ; output SPACE Character
            jsr     CHRIN                     ; get character
            lda     #$01                      ; set input start column within line
            sta     $D3
            ldx     #$80
            bne     LC701

;; entry point from "," command (assemble single line)
COMMACMD:   ldx     #$80                      ; set "commacmd" flag
            stx     MEM
LC701:      stx     FLAG
            jsr     GETADR                    ; get memory address from command line
            lda     #$25                      ; set last input char (37)
            sta     LASTCOL
            bit     MEM                       ; skip the following if "commacmd" flag NOT set
            bpl     LC717
            ldx     #$0A                      ; skip 10 characters (for "," command)
LC711:      jsr     CHRIN           
            dex
            bne     LC711
LC717:      lda     #$00
            sta     MEM
            jsr     LC6A1                     ; get a character (skip " $(,")
            cmp     #$46                      ; is it "f"?
            bne     LC739                     ; jump if not

;; disassemble the whole input and exit
            lsr     FLAG
            pla
            pla
            ldx     #$02
LC729:      lda     $FA,x                     ; swap $FB/$FC and $FD/$FE
            pha
            lda     PCH,x
            sta     $FA,x
            pla
            sta     PCH,x
            dex
            bne     LC729
            jmp     LC564                     ; disassemble
LC739:      cmp     #PERIOD                   ; is character byte a "."
            bne     LC74E                     ; jump if not
            jsr     GETBYT1
            ldy     #$00
            sta     (PCL),y                   ; store opcode
            cmp     (PCL),y                   ; compare (in case of ROM)
            bne     LC74C                     ; if different then error
            jsr     PCINC                     ; increment program counter
            iny
LC74C:      dey
            rts
        
LC74E:      ldx     #ECL
            cmp     #$4D                      ; is character byte a "M"
            bne     LC76D                     ; jump if not
            jsr     GETBYT1
            ldy     #$00
            cmp     #QUEST                    ; is character byte a "?"
            bcs     LC74C
            asl
            tay
            lda     PCL
            sta     $033C,y
            lda     PCH
            iny
            sta     $033C,y

;; read 3 opcode characters and store in $a6-$a8
LC76A:      jsr     LC6A1                     ; get new character byte
LC76D:      sta     $A9,x                     ; store character byte
            cpx     #ECL
            bne     LC777
            lda     #$07
            sta     $B7
LC777:      inx
            bne     LC76A                     ; get more character bytes (total 3)
            ldx     #$38

;; find 6502 opcode mnemonic in table
LC77C:      lda     $A6                       ; get first opcode character
            cmp     OPMN1-1,x                 ; find it in table
            beq     LC788                     ; jump if found
LC783:      dex
            bne     LC77C
            dex
            rts                               ; not found => error exit
LC788:      lda     $A7                       ; get second opcode character
            cmp     OPMN2-1,x                 ; compare with expected
            bne     LC783                     ; repeat if no match
            lda     $A8                       ; get third opcode character
            cmp     OPMN3-1,x                 ; compare with expected
            bne     LC783                     ; repeat if no match

;; 6502 opcode mnemonic found
            lda     OPC-1,x                   ; get opcode
            sta     BEFCODE                   ; store opcode
            jsr     LC6A1                     ; get another character
            ldy     #$00
            cpx     #$20
            bpl     LC7AD
            cmp     #$20
            bne     LC7B0
            lda     OPC3,x
            sta     BEFCODE
LC7AD:      jmp     LC831
LC7B0:      ldy     #$08
            cmp     #$4D
            beq     LC7D6
            ldy     #$40
            cmp     #$23
            beq     LC7D6
            jsr     ASCHEX                    ; convert to 0-15
            sta     LOPER
            nop
            sta     HOPER
            nop
            jsr     LC6A1
            ldy     #$20
            cmp     #$30
            bcc     LC7E9
            cmp     #$47
            bcs     LC7E9
            ldy     #$80
            dec     $D3
LC7D6:      jsr     LC6A1
            jsr     ASCHEX                    ; convert to 0-15
            sta     LOPER
            nop
            jsr     LC6A1
            cpy     #$08
            beq     LC7E9
            jsr     LC6BE
LC7E9:      sty     ADRCODE
            ldx     #$01
            cmp     #$58
            jsr     LC69A
            ldx     #$04
            cmp     #RPAREN                   ; is character byte a ")"
            jsr     LC69A
            ldx     #$02
            cmp     #$59
            jsr     LC69A
            lda     BEFCODE
            and     #$0D
            beq     LC810
            ldx     #$40
            lda     #$08
            jsr     LC681
            lda     #$18
            .byte  $2C                        ; skip next (2-byte) opcode
LC810:      lda     #$1C
            ldx     #$82
            jsr     LC681
            ldy     #$08
            lda     BEFCODE
            cmp     #$20
            beq     LC828
LC81F:      ldx     LC204-1,y
            lda     LC20C-1,y
            jsr     LC681
LC828:      dey
            bne     LC81F
            lda     ADRCODE
            bpl     LC830
            iny
LC830:      iny
LC831:      jsr     LC68A                     ; copy opcode plus arguments
            dec     $B7
            lda     $B7
            sta     $D3
            jmp     LC597                     ; disassemble

;; 6502 illegal opcode mnemonic found
ILLOPC:     ldx     #$02
            bne     LCE83
ILOPCM:     ldx     BEFCODE
            bne     LCE8A
            ldx     #$01
            lda     (PCL),y
            cmp     #$9C
            beq     LCE9F
            cmp     #$80
            beq     ILLOPC
            cmp     #$89
            beq     ILLOPC
            and     #$0F 
            cmp     #$02
            beq     LCE8B
            cmp     #$0A
            beq     LCE83
            inx
            cmp     #$04
            beq     LCE83
            inx
            cmp     #$0C
            bne     LCE9F
LCE83:      stx     BEFLEN
            ldx     #$01
            stx     $02C5
LCE8A:      rts
LCE8B:      lda     (PCL),y
            and     #$90
            eor     #$80
            bne     LCE97
            ldx     #$02
            bne     LCE83
LCE97:      stx     BEFLEN
            ldx     #$0A
            stx     $02C5
            rts
LCE9F:      ldy     #$02
            sty     BEFLEN
            ldy     #$00
            sty     $02C5
            lda     (PCL),y
            ldx     #$0F
LCEAC:      cmp     ILOPC,x
            beq     LCE8A
            dex
            bne     LCEAC
            and     #$01
            beq     LCE8A
            lda     (PCL),y
            lsr
            lsr
            lsr
            lsr
            lsr
            clc
            adc     #$02
            sta     $02C5
            ldx     #$0B
ICEC7:      lda     (PCL),y
            and     LCE40,x
            cmp     LCE40,x
            beq     LCED4
            dex
            bne     ICEC7
LCED4:      lda     LCE36-1,x
            sta     ADRCODE
            lda     LCE4B,x
            sta     BEFLEN
            rts
ILOPCD:     ldy     #$00
            ldx     BEFCODE
            beq     LCEEB
            jsr     SPACE                     ; output space
            jmp     LC5DA
LCEEB:      ldx     $02C5
            bne     LCEF6
            jsr     SPACE                     ; output space
            jmp     LC5C9
LCEF6:      lda     #$2A
            jsr     CHROUT
            lda     ILOPMN1-1,x
            jsr     CHROUT
            lda     ILOPMN2-1,x
            jsr     CHROUT               
            lda     ILOPMN3-1,x
            jmp     LC616

        
;; HEXADECIMAL ADDITION AND SUBTRACTION (?)
ADDSUB:     jsr     GETADR
            jsr     GETCHRET                  ; get next character until a carriage return
            eor     #$02
            lsr
            lsr
            php
            jsr     GETADRX
            jsr     RETURN                    ; output ASCII carriage return (CR)
            plp
            bcs     LC8BA
            lda     ECL
            adc     PCL
            tax
            lda     ECH
            adc     PCH
LC8B7:      sec
            bcs     LC8C3
LC8BA:      lda     PCL
            sbc     ECL
            tax
            lda     PCH
            sbc     ECH
LC8C3:      tay
LC8C4:      txa

;; output 16-bit integer in A/Y as HEX, binary and decimal
LC8C5:      sty     PCH
            sta     PCL
            sty     $62
            sta     $63
            php
            lda     #$00
            sta     $D3
            jsr     LC675
            lda     PCH
            bne     LC8E8
            jsr     DBLSPACE                  ; output two SPACE Characters
            lda     PCL
            jsr     HEXOUT1
            lda     PCL
            jsr     FLG2BIN                   ; display processor flags as binary string
            beq     LC8EB
LC8E8:      jsr     HEXOUT
LC8EB:      jsr     SPACE                     ; output SPACE Character
            ldx     #$90
            lda     $01
            sta     MEM
            lda     #$37
            sta     $01
            plp
            ldx     MEM
            stx     $01
            jmp     PRTDEC16
        
;; CONVERT HEXADECIMAL ($)
BEFHEX:     jsr     GETBYT
            tax
            ldy     $D3
            lda     ($D1),y
            eor     #$20
            beq     LC8B7
            txa
            tay
            jsr     GETBYT1
LC919:      sec
            bcs     LC8C5

;; CONVERT BINARY (%)
BEFBIN:     jsr     SKIPSPACE
            ldy     #$08
LC921:      pha
            jsr     GETCHRET                  ; get next character until a carriage return
            cmp     #$31
            pla
            rol
            dey
            bne     LC921
            beq     LC919

;; CONVERT DECIMAL (#)
BEFDEC:     jsr     SKIPSPACE
            ldx     #$00
            txa
LC934:      stx     PCL
            sta     PCH
            tay
            jsr     CHRIN
            cmp     #COLON                    ; is character byte a ":"
            bcs     LC8C4
            sbc     #$2F
            bcs     LC948
            sec
            jmp     LC8C4
LC948:      sta     ECL
            asl     PCL
            rol     PCH
            lda     PCH
            sta     ECH
            lda     PCL
            asl
            rol     ECH
            asl
            rol     ECH
            clc
            adc     PCL
            php
            clc
            adc     ECL
            tax
            lda     ECH
            adc     PCH
            plp
            adc     #$00
            jmp     LC934
        
;; WRITE (W) - move memory
WRITE:      jsr     GET3ADR
            jsr     RETURN                    ; output ASCII carriage return (CR)
WRITE1:     lda     ADRBUF+2                  ; load address buffer $A6
            bne     LC9DC
            dec     ADRBUF+3                  ; decrement memory address in address buffer $A7
LC9DC:      dec     ADRBUF+2                  ; decrement memory address in address buffer $A6
            jsr     LCA30
            stx     $B5
            ldy     #$02
            bcc     LC9EB
            ldx     #$02
            ldy     #$00
LC9EB:      clc
            lda     ADRBUF+2                  ; load new memory address in address buffer $A6
            adc     $AE
            sta     FLAG
            lda     ADRBUF+3                  ; load new memory address in address buffer $A7
            adc     $AF
            sta     ADRCODE
LC9F8:      lda     (ADRBUF,x)                ; load value in address buffer $A4 with index x
            sta     (ADRBUF+4,x)              ; store address buffer $A8 with index x
            eor     (ADRBUF+4,x)              ; exclusive-OR address buffer $A8 with accumulator
            ora     $B5
            sta     $B5
            lda     ADRBUF                    ; load value in address buffer $A4
            cmp     ADRBUF+2                  ; compare accumulator with address buffer $A6
            lda     ADRBUF+1                  ; address buffer $A5
            sbc     $A7
            bcs     LCA29
LCA0C:      clc
            lda     ADRBUF,x                  ; load value in address buffer $A4 with index x
            adc     OFFSET,y
            sta     ADRBUF,x                  ; store value in address buffer $A4 with index x
            lda     ADRBUF+1,x                ; load value in address buffer $A5 with index x
            adc     OFFSET+1,y
            sta     ADRBUF+1,x                ; store value in address buffer $A5 with index x
            txa
            clc
            adc     #$04
            tax
            cmp     #$07
            bcc     LCA0C
            sbc     #$08
            tax
            bcs     LC9F8
LCA29:      lda     $B5
            beq     LCA3C
            jmp     ERROR
LCA30:      sec
            ldx     #ECH
LCA33:      lda     FLAG,x
            sbc     $A6,x
            sta     $B0,x
            inx
            bne     LCA33
LCA3C:      rts

;; CONVERT (C) - do V followed by W
CONVERT:    jsr     LCA62                     ; convert addresses
            jmp     WRITE1                    ; move memory

;; SHIFT (V) - convert addresses referencing a memory region
MOVE:       jmp     LCA62
LCA46:      cmp     ADRBUF+3                  ; compare address buffer $A7 with accumulator
            bne     LCA4C
            cpx     ADRBUF+2                  ; compare address buffer $A6 with X register
LCA4C:      bcs     LCA61
            cmp     ADRBUF+1                  ; compare address buffer $A5 with accumulator
            bne     LCA54
            cpx     ADRBUF                    ; compare address buffer $A4 with X register
LCA54:      bcc     LCA61
            sta     $B4
            txa
            clc
            adc     $AE
            tax
            lda     $B4
            adc     $AF
LCA61:      rts      
LCA62:      jsr     GET3ADR                   ; get address range and destination
            jsr     GETDW                     ; get range
            jsr     RETURN                    ; output ASCII carriage return (CR)
MOVE1:      jsr     LCA30                     
LCA6B:      jsr     LC4CB
            iny
            lda     #$10
            bit     ADRCODE
            beq     LCA9B
            ldx     PCL
            lda     PCH
            jsr     LCA46
            stx     FLAG
            lda     (PCL),y
            sta     $B5
            jsr     LC54A
            ldy     #$01
            jsr     LCA46
            dex
            txa
            clc
            sbc     FLAG
            sta     (PCL),y
            eor     $B5
            bpl     LCAAE
            jsr     RETURN                    ; output ASCII carriage return (CR)
            jsr     HEXOUT
LCA9B:      bit     ADRCODE
            bpl     LCAAE
            lda     (PCL),y
            tax
            iny
            lda     (PCL),y
            jsr     LCA46
            sta     (PCL),y
            txa
            dey
            sta     (PCL),y
LCAAE:      jsr     LC66A
            jsr     CMPEND1
            bcc     LCA6B
            rts

;; LISTS ASCII CHARACTERS IN MEMORY (K)
KONTROLLE:  jsr     GETADRSE
LCABA:      ldx     #$27
            jsr     CHARRTN                   ; New line followed by a character from x
            jsr     HEXOUT                    ; output as 4 digit hex
            ldy     #$08
            ldx     #$00
            jsr     SPACE                     ; output SPACE Character
LCAC9:      lda     (PCL,x)                   ; get next byte
            jsr     ASCII                     ; write ASCII char of byte directly to screen
            bne     LCAC9                     ; repeat until end of line
            jsr     PREOL                     ; print to end of line
            ldx     #$00
            jsr     CHECKEND
            beq     LCADA
            jmp     LCABA
LCADA:      rts

;; TICK (' - read ASCII chars to memory)
TICK:       jsr     GETADR                    ; get starting memory address
            ldy     #$03                      ; skip up to 3 spaces
LCAE0:      jsr     CHRIN
            cmp     #SP                       ; is character byte a space " "
            bne     TSTRT                     ; jump if not
            dey
            bne     LCAE0
TLOOP:      jsr     CHRIN                     ; get character
TLOOP1:     cmp     #CR                       ; is character byte a carriage return
            beq     TEND                      ; done if so
            sta     (PCL),y                   ; store character
LCAEF:      iny
            cpy     #72                       ; do we have 72 characters yet?
            bcc     TLOOP                     ; loop if not
TEND:       rts
TSTRT:      ldy     #0
            jmp     TLOOP1

EQUALS:     jsr     GETDW
            ldx     #$00
LCAFA:      lda     (PCL,x)
            cmp     (ECL,x)
            bne     LCB0B
            jsr     PCINC                     ; increment program counter
            inc     ECL
            bne     LCAFA
            inc     ECH
            bne     LCAFA
LCB0B:      jsr     SPACE                     ; output SPACE Character
            jmp     HEXOUT
        
;; FIND (F)
FIND:       lda     #$FF                      ; set start and end address to $FFFF
            ldx     #$04
LCB15:      sta     $FA,x
            dex
            bne     LCB15
            jsr     GETCHRET                  ; get next character byte until a carriage return
            ldx     #$05
LCB1F:      cmp     FSCMD-1,x                 ; compare with sub-command char (AZIRT)
            beq     LCB69                     ; jump if found
            dex
            bne     LCB1F                     ; repeat until all checked

;; no sub-command found => plain "F" (find bytes)
;; (X=0 at this point)
LCB27:      stx     $A9                       ; store number of bytes
            jsr     LCBB4                     ; get search data for byte (two nibbles+bit masks)
            inx                               ; next byte
            jsr     CHRIN                     ; get next character byte
            cmp     #SP                       ; is character byte a space " "
            beq     LCB27                     ; skip if so
            cmp     #COMMA                    ; is character byte a ","
            bne     LCB3B                     ; repeat if not
            jsr     GETDW                     ; get start and end address of range
LCB3B:      jsr     RETURN                    ; output ASCII carriage return (CR)
LCB3E:      ldy     $A9                       ; get number of bytes in sequence
LCB40:      lda     (PCL),y                   ; get next byte in memory
            jsr     LCBD6                     ; compare A with byte in expected sequence
            bne     LCB5F                     ; jump if no match
            dey                               ; next byte
            bpl     LCB40                     ; repeat until last byte in dequence
            jsr     HEXOUT                    ; found a match => print current address
            jsr     SPACE                     ; output SPACE Character
            ldy     $D3                       ; get cursor column
            cpy     #76                       ; compare to 76
            bcc     LCB5F                     ; jump if less
            jsr     KBDKEY                    ; handle PAUSE/STOP
            jsr     RETURN                    ; output ASCII carriage return (CR)
LCB5F:      jsr     CMPEND                    ; increment current location and check end
            bcc     LCB3E                     ; repeat if end has not been reached
            ldy     #$27
            rts

;; execute "find" sub-command AZIRT with index in X
LCB69:      lda     FSFLAG-1,x
            sta     ADRBUF+4                  ; store accumulator in address buffer $A8
            lda     FSFLAG1-1,x               ; get length of data item (2=word/1=byte/0=none)
            sta     ADRBUF+5                  ; store address buffer $A9 into accumulator
            tax                               ; into x
            beq     LCB7C                     ; skip getting argument if 0
LCB76:      jsr     LCBB4                     ; get two nibbles
            dex                               ; do we need more (i.e. word)?
            bne     LCB76                     ; jump if so
LCB7C:      jsr     GETDW                     ; get start and end address
LCB7F:      jsr     LC4CB
            jsr     LC52C
            lda     ADRBUF+4                  ; load address buffer $A8 in accumulator
            bit     ADRCODE
            bne     LCB94
            tay
            bne     LCBAF
            lda     BEFCODE
            bne     LCBAF
            beq     LCBA1
LCB94:      ldy     ADRBUF+5                  ; load address buffer $A9 into Y register
LCB96:      lda     BEFCODE,y
            jsr     LCBD6
            bne     LCBAF
            dey
            bne     LCB96
LCBA1:      sty     FLAG
            jsr     LC58C                     ; disassemble one opcode at current addres
            jsr     KBDKEY                    ; handle PAUSE/STOP
LCBA9:      jsr     CMPEND1                   ; check whether end address has been reached
            bcc     LCB7F                     ; repeat if not
            rts
        
LCBAF:      jsr     LC66A
            beq     LCBA9

;; get two nibbles with bit mask from command line
;; first  goes into $036C+x (bit mask in $03CC+x)
;; second goes into $033C+x (bit mask in $039C+x)
LCBB4:      jsr     LCBC0
            sta     $03CC,x
            lda     $033C,x
            sta     $036C,x
        
;; get nibble from command line, checking for wildcard ('*')
LCBC0:      jsr     GETCHRET                  ; get next character byte until a carriage return
            ldy     #$0F                      ; bit mask $0F
            cmp     #AST                      ; is character byte a '*'?
            bne     LCBCB                     ; jump if not
            ldy     #$00                      ; bit mask $00
LCBCB:      jsr     ASCHEX1                   ; convert char to nibble $0-$F
            sta     $033C,x                   ; store nibble
            tya
            sta     $039C,x                   ; store bit mask
            rts

;; compare byte in A with byte Y of expected sequence
;; return with Z set if matching
LCBD6:      sta     $B4                       ; temp storage
            lsr                               ; get high nibble into low
            lsr
            lsr
            lsr
            eor     $036C,y                   ; zero-out bits that match for high nibble
            and     $03CC,y                   ; zero-out bits according to bit mask for high nibble
            and     #$0F                      ; only bits 0-3
            bne     LCBF0                     ; if not zero then we have a difference
            lda     $B4                       ; get byte back
            eor     $033C,y                   ; zero-out bits that match for low nibble
            and     $039C,y                   ; zero-out bits according to bit mask for low nibble
            and     #$0F                      ; only bits 0-3
LCBF0:      rts

;; MEMORY SIZE (MS)
MEMSIZ:     ldx     #3
MSL1:       ldx     #$01                      ; get 00,01,FF,FF
            stx     PCH                       ; into FB-FE
            dex
            stx     PCL
            dex
            stx     ECL
            stx     ECH
            jsr     RETURN                    ; output ASCII carriage return (CR)
            ldx     #$00
MSL2:       lda     (PCL,x)                   ; save current value
            tay
            lda     #$55
            sta     (PCL,x)
            cmp     (PCL,x)
            bne     MSL5
            lda     #FLAG
            sta     (PCL,x)
            cmp     (PCL,x)
            bne     MSL5
MSL4:       tya
            sta     (PCL,x)                   ; restore original value
            jsr     PCINC                     ; increment program counter
            jsr     CMPEND1                   ; check if we've tested the whole range
            bcc     MSL2                      ; repeat if not
            .byte   $2C                       ; skip following 2-byte opcode
MSL5:       sta     (PCL,x)
            jsr     HEXOUT                    ; print current address
            rts                               ; done
        
;; MEMORY TEST (MT)
MEMTST:     ldx     #ADRBUF                   ; load address buffer $A4
            jsr     GETADRX                   ; get start address
            jsr     GETADRX                   ; get end address
            ldy     #1                        ; default: 1 repetition
            jsr     GETRETURN                 ; do we have more arguments?
            beq     MTL1                      ; skip if not
            jsr     GETBYT                    ; get number of repetitions
            tay
MTL1:       sty     $FF                       ; store number of repetitions
            lda     PCH                       ; get high byte of start address
            bne     MTL2                      ; is it greater than zero?
            jmp     ERROR                     ; no => can't test zero-page memory
MTL2:       jsr     RETURN                    ; output ASCII carriage return (CR)
MTL3:       ldx     #3
MTL4:       lda     ADRBUF,x                  ; get start and end address back from address buffer $A4
            sta     PCL,x                     ; from temp to FB-FE
            dex
            bpl     MTL4
            ldx     #0
MTL5:       lda     (PCL,x)                   ; save current program counter (low byte) value
            tay
            lda     #$00
            sta     (PCL,x)
            cmp     (PCL,x)
            bne     MTL6
            lda     #$55
            sta     (PCL,x)
            cmp     (PCL,x)
            bne     MTL6
            lda     #FLAG
            sta     (PCL,x)
            cmp     (PCL,x)
            bne     MTL6
            lda     #$FF
            sta     (PCL,x)
            cmp     (PCL,x)
            beq     MTL7
MTL6:       jsr     HEXOUT                    ; fail: output current address
            jsr     SPACE                     ; output SPACE Character
MTL7:       tya
            sta     (PCL,x)                   ; restore original value
            jsr     PCINC                     ; increment program counter
            jsr     CMPEND1                   ; check if we've tested the whole range
            bcc     MTL5                      ; repeat if not
            lda     #PLUS                     ; load accumulator with plus character byte "+"
            jsr     CHROUT                    ; output plus character "+"
            dec     $FF                       ; decrement repetition count
            bne     MTL3                      ; go again until 0
            rts
        
;; TRACE (T)
TRACE:      .if     VIA == 0
              jmp     ERROR                   ; can only do trace if we have a VIA
            .endif
            pla
            pla
            jsr     CHRIN
            jsr     UCASE
            cmp     #$57                      ; is character byte a "W"
            bne     LCBFD                     ; jmp to next condition if not true
            jmp     LCD56                     ; TW command
LCBFD:      cmp     #$42                      ; is character byte a "B"
            bne     LCC04                     ; jmp to next condidition if not true
            jmp     LCDD0                     ; TB command
LCC04:      cmp     #$51                      ; is character byte a "Q"
            bne     LCC0B                     ; jmp to next condition if not true
            jmp     LCD4F                     ; TQ command
LCC0B:      cmp     #$53                      ; is character byte a "S"
            beq     LCC12                     ; TS command
            jmp     ERROR                     ; generate an error if there is no match

;; TRACE STOP (TS)
LCC12:      jsr     GETBYT
            pha
            jsr     GETBYT
            pha
            jsr     GETSTART
            ldy     #$00
            lda     (PCL),y
            sta     TRACEBUF+4                ; $02BC trace buffer memory address
            tya
            sta     (PCL),y
            lda     #<TBINT                   ; set BREAK vector
            sta     BRK_LO                    ; to breakpoint entry
            lda     #>TBINT
            sta     BRK_HI
            ldx     #PCH
            jmp     GO_LOOP

;; entry point after breakpoint is hit
TBINT:      ldx     #$03
LCC38:      pla
            sta     SRSAVE,x                  ; store processor status flag register
            dex
            bpl     LCC38
            pla
            pla
            tsx
            stx     SPSAVE                    ; store stack pointer
            lda     PCHSAVE                   ; load program counter (high byte) into accumulator
            sta     PCH                       ; restore program counter (high byte)
            lda     PCLSAVE                   ; load program counter (low byte) into accumulator
            sta     PCL                       ; restore program counter (low byte)
            lda     TRACEBUF+4                ; $02BC trace buffer memory address
            ldy     #$00
            sta     (PCL),y
            lda     #<BREAK                   ; restore BREAK vector
            sta     BRK_LO                    ; to SMON main loop
            lda     #>BREAK
            sta     BRK_HI
            lda     #$52
            jmp     CMDSTORE
LCC65:      jsr     RETURN                    ; output ASCII carriage return (CR)
RTSCMD:     rts
            sta     AKSAVE                    ; store accumulator value
            php
            pla
            and     #$EF
            sta     SRSAVE                    ; store processor status flag register
            stx     XRSAVE                    ; store X register value
            sty     YRSAVE                    ; store Y register value
            pla
            clc
            adc     #$01
            sta     PCLSAVE                   ; store program counter (low byte) value
            pla
            adc     #$00
            sta     PCHSAVE                   ; store program counter (high byte) value
            lda     #$80
            sta     TRACEBUF+4                ; $02BC trace buffer memory address
            bne     LCCA5

;; entry point from TW after an instruction has been executed
;; (via timer interrupt)
TWINT:      lda     #$40                      ; clear VIA timer 1 interrupt flag
            sta     VIA_IFR
            jsr     LCDE5                     ; restore IRQ vector
            cld                               ; make sure "decimal" flag is not set
            .if UART_TYPE==6522               ; if VIA is also used as UART
              lda     #$40                    ; set T1 free run, T2 clock ?2
              sta     VIA_CR                  ; set VIA 1 ACR
              lda     #$40                    ; disable VIA timer 1 interrupt
	      sta     VIA_IER                 ; set VIA 1 IER
              lda     #$90                    ; enable VIA CB1 interrupt
	      sta     VIA_IER                 ; set VIA 1 IER
            .endif
            ldx     #$05                      ; get registers from stack
LCC9E:      pla                               ; (were put there when IRQ happened)
            sta     PCHSAVE,x                 ; store them in PCHSAVE memory location x
            dex
            bpl     LCC9E
LCCA5:      lda     IRQ_LO                    ; save IRQ pointer
            sta     TRACEBUF+3                ; $02BB trace buffer memory address
            lda     IRQ_HI
            sta     TRACEBUF+2                ; $02BA trace buffer memory address
            tsx
            stx     SPSAVE                    ; store stack pointer
            cli                               ; allow interrupts     
            lda     SRSAVE                    ; load processor status flag register into accumulator
            and     #$10
            beq     LCCC5
LCCBD:      jsr     LCC65
            lda     #$52
            jmp     CMDSTORE
LCCC5:      bit     TRACEBUF+4                ; $02BC trace buffer memory address
            bvc     LCCE9
            sec
            lda     PCLSAVE                   ; restore program counter (low byte)
            sbc     TRACEBUF+5                ; subtract $02BD trace buffer memory address
            sta     MEM
            lda     PCHSAVE                   ; restore program counter (high byte)
            sbc     TRACEBUF+6                ; subtract $02BE trace buffer memory address
            ora     MEM
            bne     LCD46
            lda     TRACEBUF+7                ; $02BF trace buffer memory address
            bne     LCD43
            lda     #$80
            sta     TRACEBUF+4                ; $02BC trace buffer memory address
LCCE9:      bmi     LCCFD
            lsr     TRACEBUF+4                ; $02BC trace buffer memory address
            bcc     LCCBD
            ldx     SPSAVE                    ; load stack pointer into X register
            txs
            lda     #>RTSCMD
            pha
            lda     #<RTSCMD
            pha
            jmp     LCDBA
LCCFD:      jsr     LCC65
            lda     #ADRBUF+4                 ; load address buffer $A8 into accumulator
            sta     PCL                       ; store accumulator into program counter (low byte)
            lda     #$02
            sta     PCH
            jsr     SPACE                     ; output SPACE Character
            ldy     #$00
LCD0D:      lda     (PCL),y
            jsr     HEXOUT1
            iny
            cpy     #$07
            beq     LCD20
            cpy     #$01
            beq     LCD0D
            jsr     SPACE                     ; output SPACE Character
            bne     LCD0D
LCD20:      lda     PCLSAVE                   ; restore program counter (low byte) into accumulator
            ldx     PCHSAVE                   ; restore program counter (high byte) into X register
            sta     PCL                       ; set program counter to current address (low byte)
            stx     PCH                       ; set program counter to current address (high byte)
            jsr     SPACE                     ; output a SPACE character
            lda     SRSAVE                    ; load processor status flag register into accumulator
            jsr     FLG2BIN                   ; output processor flag binary string
            jsr     DBLSPACE                  ; output two SPACE characters
            jsr     LC4CB                     ; disassemble 6502 opcodes
            jsr     ILOPCD                    ; disassemble 6502 illegal opcodes 
LCD33:      jsr     GETIN                     ; get next byte from input (kernal subroutine)
            beq     LCD33                     ; wait until we have something
            cmp     #$4A                      ; was it 'J'?
            bne     LCD46                     ; jump if not
            lda     #$01
            sta     TRACEBUF+4                ; $02BC trace buffer memory address
            bne     LCD72                     ; take next TW step
LCD43:      dec     TRACEBUF+7                ; $02BF trace buffer memory address
LCD46:      lda     $91                       ; get "STOP" flag
            cmp     #$7F                      ; is it set?
            bne     LCD72                     ; if not, take next TW step
            jmp     LCCBD

;; TRACE QUICK (TQ)
LCD4F:      jsr     LCDF2
            lda     #$40
            bne     LCD60
     
;; TRACE WALK (TW)
LCD56:      jsr     LCDF2
            php
            pla
            sta     SRSAVE                    ; store processor status flag register
            lda     #$80
LCD60:      sta     TRACEBUF+4                ; $02BC trace buffer memory address
            tsx
            stx     SPSAVE                    ; store stack pointer
            jsr     GETSTART
            jsr     LCC65
            lda     TRACEBUF+4                ; $02BC trace buffer memory address
            beq     LCDA9
LCD72:      .if UART_TYPE==6522               ; if VIA is also used as UART
              lda     VIA_IER                 ; get enabled VIA interrupts
              and     #$60                    ; isolate T1 and T2 interrupts
              bne     LCD72                   ; wait until both disabled (UART is idle)
            .endif
            sei
            lda     #$7F
            sta     VIA_IER                   ; disable all VIA interrupts
            lda     #$C0
            sta     VIA_IER                   ; enable VIA timer 1 interrupt
            lda     #$00
            sta     VIA_CR                    ; VIA timer 1 single-shot mode
            ldx     #0
            lda     #73                       ; 73 cycles until timer expires
            sta     VIA_T1LL                  ; set VIA timer 1 low-order latch 
            stx     VIA_T1CH                  ; set VIA timer 1 high-order counter (start timer)
            lda     #<TWINT                   ; (2)
            ldx     #>TWINT                   ; (2)
            sta     TRACEBUF+3                ; (4) $02BB trace buffer memory address
            stx     TRACEBUF+2                ; (4) $02BA trace buffer memory address
LCDA9:      ldx     SPSAVE                    ; (4) load stack pointer into X register
            txs                               ; (2)
            cli                               ; (2)
            lda     TRACEBUF+3                ; (4) $02BB trace buffer memory address
            ldx     TRACEBUF+2                ; (4) $02BA trace buffer memory address
            sta     IRQ_LO                    ; (4)
            stx     IRQ_HI                    ; (4)
LCDBA:      lda     PCHSAVE                   ; (4) load program counter (high byte) into accumulator
            pha                               ; (3)
            lda     PCLSAVE                   ; (4) load program counter (low byte) into accumulator
            pha                               ; (3)
            lda     SRSAVE                    ; (4) load processor status flag register into accumulator
            pha                               ; (3)
            lda     AKSAVE                    ; (4) restore accumulator
            ldx     XRSAVE                    ; (4) restore X register
            ldy     YRSAVE                    ; (4) restore Y register
            rti                               ; (6) => total 75 cycles, timer expires during RTI?

;; TRACE BREAK (TB)
LCDD0:      jsr     GETBYT
            sta     TRACEBUF+6                ; $02BE trace buffer memory address
            jsr     GETBYT
            sta     TRACEBUF+5                ; $02BD trace buffer memory address
            jsr     GETBYT
            sta     TRACEBUF+7                ; $02BF trace buffer memory address
            jmp     EXECUTE                   ; back to main loop (resets stack)

;; restore IRQ vector
LCDE5:      lda     TRACEBUF                  ; $02B8 trace buffer memory address
            ldx     TRACEBUF+1                ; $02B9 trace buffer memory address
            sta     IRQ_LO
            stx     IRQ_HI
            rts

;; save IRQ vector and set BRK vector to entry point
LCDF2:      lda     IRQ_LO
            ldx     IRQ_HI
            sta     TRACEBUF                  ; $02B8 trace buffer memory address
            stx     TRACEBUF+1                ; $02B9 trace buffer memory address
            lda     #<TWINT
            sta     BRK_LO
            lda     #>TWINT
            sta     BRK_HI
            rts

;; EXIT SMON (X)        
EXIT:       jsr     RETURN                    ; output ASCII carriage return (CR)
            jmp     UAEXIT                    ; exit subroutine in seperate chipset asm file


;; print 16-bit integer in $62/$63 as decimal value, adapted from:
;; https://beebwiki.mdfs.net/Number_output_in_6502_machine_code#16-bit_decimal

PAD         :=  0
NUM         := $63
PRPOW:      .word 1, 10, 100, 1000, 10000

PRTDEC16:   LDY #8                            ; offset to powers of ten
PRDEC16LP1:   
            LDX #$FF
            SEC                               ; start with digit=-1
PRDEC16LP2:   
            LDA NUM
            SBC PRPOW,Y
            STA NUM                           ; subtract current tens
            LDA NUM-1
            SBC PRPOW+1,Y
            STA NUM-1
            INX
            BCS PRDEC16LP2                    ; loop until < 0
            LDA NUM                           ; add current tens back in
            ADC PRPOW,Y
            STA NUM
            LDA NUM-1
            ADC PRPOW+1,Y
            STA NUM-1
            TXA
            BNE PRDEC16DIGIT                  ; leading zero => skip
            LDA PAD
            BNE PRDEC16PRINT
            BEQ PRDEC16NEXT                   ; pad <> 0, add 0
PRDEC16DIGIT:   
            LDX #'0'        
            STX PAD                           ; no more zero padding
            ORA #'0'                          ; convert to 0-9 digit
PRDEC16PRINT:   
            JSR CHROUT                        ; output character
PRDEC16NEXT:
            DEY
            DEY
            BPL PRDEC16LP1                    ; Loop for next digit
            RTS

;;; ----------------------------------------------------------------------------
;;; ---------------------------  C64 KERNAL routines   -------------------------
;;; ----------------------------------------------------------------------------

LINEBUF     := $0400                          ; line ("screen") buffer memory start
NUMCOLS     := 80                             ; number of columns per row
NUMROWS     := 24                             ; number of rows
INPUT_UCASE := 0                              ; do not automatically convert input to uppercase
SUPPRESS_NP := 0                              ; do not suppress any characters on output
        
 .include "kernal.asm"
