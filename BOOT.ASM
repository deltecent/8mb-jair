;****************************************************************************
;
;  CP/M cold boot loader for Altair CP/M using virtual Altair 8" floppy
;    drives served through an 88-2SIO serial port.
;
;    This code is loaded from sectors 0 and 2 into RAM by the disk boot
;    loader PROM. This loader, in turn, loads the CP/M image into RAM.
;
;    Version History
;
;    Ver     Date	  Description
;    ---   ---------	---------------------
;    1.0   10/28/23	Original, Mike Douglas
;    1.1   11/26/23     Clear out any left over bytes coming from the
;			server when an error has occurred.
;
;--------------------------------------------------------------------------
;
;    To patch changes made to this loader into a CP/M image saved from
;    MOVCPM2S (e.g., CPMxx.COM), use the following commands:
;
;	A>DDT CPMxx.COM
;	-IBOOT.HEX
;	-R900
;       -M980,9FF,A00	(splits code onto sectors 0 and 2)
;	-G0	    	(Go zero, not "oh")
;	A>SYSGEN
;
;****************************************************************************

MEMSIZE	equ	56		;set memory size in K bytes

; 8" floppy equates

NUMSEC	equ	32		;sectors per track
PSECLEN	equ	137		;physical sector length
CSECLEN	equ	128		;CP/M sector length
TRKLEN	equ	NUMSEC*PSECLEN
SYSDATA	equ	3		;offset of 128 byte data payload in sector
STRTSEC	equ	3		;starting sector of CP/M image on track 0

; CP/M size & locations

CCPLEN	equ	0800h		;CPM 2.2 fixed length
BDOSLEN	equ	0E00h		;CPM 2.2 fixed length
BIOSLEN	equ	1C00h		;length of BIOS for 8MB serial drive

CCPBASE	equ	MEMSIZE*1024 - BIOSLEN - BDOSLEN - CCPLEN
BIOSBAS	equ	(CCPBASE+CCPLEN+BDOSLEN) ;base address of this BIOS

; Server serial port is port B on 88-2SIO

SRVRCTL	equ	12h		;control/status port
SRVRDAT	equ	13h		;data port
SIORDRF	equ	01h		;receive data ready
SIOTDRE	equ	02h		;tranmsit data register empty

;--------------------------------------------------------------------------
;  Entry point
;--------------------------------------------------------------------------
	org	0

start	di			;disable interrupts
	lxi	sp,CCPBASE	;stack grows down from lowest CPM address
	mvi	a,03h		;reset the server serial port
	out	SRVRCTL
	mvi	a,15h		;8N1
	out	SRVRCTL

; Load and move 1st track

load	call	srb3ms		;discard received bytes until 3ms passes
	jz	load		;   with no data received

	xra	a		;track 0
	sta	trkNum
	mvi	a,CSUMVAL AND 0FFh  ;re-init checksum
	sta	chkSum
	call	readTrk		;read the track
	jnz	load		;error
	
	lxi	h,trkBuf+(STRTSEC*PSECLEN)+SYSDATA   ;source pointer
	lxi	d,CCPBASE	;DE->where to put CP/M
	mvi	c,NUMSEC-3	;sector count to move

secLp1	call	movSec		;move 128 bytes to run location
	dcr	c		;decrement sector count		
	jnz	secLp1

; Load and move second track

	lxi	h,trkNum	;move to track 1
	inr	m
	lxi	h,chkSum	;update checksum
	inr	m
	call	readTrk		;read second track
	jnz	load		;error
	
	lxi	h,trkBuf+SYSDATA   ;source pointer
	lxi	d,CCPBASE+CSECLEN*(NUMSEC-3)	;dest pointer
	mvi	c,NUMSEC	;sector count to move

secLp2	call	movSec		;move 128 bytes to run location
	dcr	c		;decrement sector count		
	jnz	secLp2

	jmp	BIOSBAS		;jump to BIOS cold start

;--------------------------------------------------------------------------
; movSec - Move 128 byte sector from trkBuf to RAM
;
; On Entry
;    HL->data portion of sector in trkBuf
;    DE->where to put sector
;
; On Exit
;    HL and DE point to next sector 
; Clobbers B,D,E,H,L
;----------------------------------------------------------------------------
movSec	mvi	b,CSECLEN	;B=count of bytes to move

msLoop	mov	a,m		;move sector from trkBuf to run location
	stax	d
	inx	h		;increment pointers
	inx	d
	dcr	b		;loop count
	jnz	msLoop
 	
	push	b		;increment source pointer
	lxi	b,PSECLEN-CSECLEN
	dad	b
	pop	b
	ret

;----------------------------------------------------------------------------
; readTrk- read full track into track buffer
;
; On Entry
;    trkNum = track to read
;
; On Exit
;    track read into trkBuf
;    Clobbers all
;----------------------------------------------------------------------------
readTrk	lxi	h,readCmd	;send read command to server
	mvi	b,CMDLEN	;B=count of bytes to send

waitSnd	in	SRVRCTL		;loop until OK to send
	ani	SIOTDRE	
	jz	waitSnd

	mov	a,m		;A=byte to send
	out	SRVRDAT		;send it

	inx	h		;point to next byte
	dcr	b		;decrement byte count
	jnz	waitSnd		;loop until command is sent

	in	SRVRDAT		;clear out any possible garbage bytes
	in	SRVRDAT

	lxi	h,trkBuf	;receive track data into trkBuf
	lxi	d,TRKLEN	;DE=length to read
	lxi	b,0		;BC=checksum

rtLoop	call	srByte		;get a byte
	rnz			;timeout error
	mov	m,a		;save byte in the buffer

	add	c		;update checksum
	mov	c,a
	mvi	a,0
	adc	b
	mov	b,a

	inx	h		;increment buffer pointer
	dcx	d		;decrement byte counter
	mov	a,d
	ora	e
	jnz	rtLoop		;loop until zero

; Receive and compare 16 bit checksum

	call	srByte		;get LSB of checksum
	rnz			;timeout
	cmp	c		;match?
	rnz			;no
		
	call	srByte		;get MSB of checksum
	rnz			;timeout
	cmp	b		;match?
	ret			;return with status

;-------------------------------------------------------------------
; srByte - Receive a byte from the server with 1 second timeout.
;    Returns zero false for timeout, else true.
;
; srb3ms does the same thing but with a 3ms timeout
;-------------------------------------------------------------------
srb3ms	push	b		;popped later, so must push
	lxi	b,125		;3ms timeout
	jmp	srbLoop

srByte	push	b		;preserve BC
	lxi	b,41667		;1 second (48 cycles, 24us per loop)
	
srbLoop	in	SRVRCTL		;(10)
	rrc			;(4)
	jc	srbNew		;(10)

	dcx	b		;(5)
	mov	a,b		;(5)
	ora	c		;(4)
	jnz	srbLoop		;(10)

	pop	b
	inr	a		;zero false for timeout
	ret

srbNew	pop	b		;restore BC
	xra	a		;zero true
	in	SRVRDAT		;get and return the byte
	ret

;-------------------------------------------------------------------
; srvrClr - Pull and discard bytes received from server until no
;    more bytes are received. A 3ms timeout between characters is 
;    used to detect end of data. This gives plenty off headroom 
;    down to 9600 baud. 
;-------------------------------------------------------------------
srvrClr	push	b		;srbLoop pops B
	lxi	b,125		;3ms timeout
	call	srbLoop		;discard received bytes
	jz	srvrClr		;  until timeout
	ret

;---------------------------------------------------------------------------
; Data Area
;---------------------------------------------------------------------------
CSUMVAL	equ	'R'+'E'+'A'+'D'+(TRKLEN/256)+(TRKLEN AND 0FFh)

readCmd	db	'READ'		;read command to server
trkNum	db	0		;track number to read
drvNum	db	0
readLen	dw	TRKLEN
chkSum	dw	CSUMVAL
CMDLEN	equ	$-readCmd

trkBuf	equ	$		;track buffer

	end
