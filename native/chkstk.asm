; __chkstk for the freestanding module (no CRT): recent MSVC toolsets (14.44) call it for functions with large locals and
; the link then fails (issue #4). The usual x64 probe: rax = bytes the caller will allocate; every page between the
; current stack limit and the new stack pointer is touched in order, so that the guard page moves down one page at a time.
; r10 and r11 are kept, as the compiler expects.

_TEXT SEGMENT

PUBLIC __chkstk

__chkstk PROC
        sub     rsp, 10h
        mov     [rsp], r10
        mov     [rsp+8], r11
        xor     r11, r11
        lea     r10, [rsp+18h]          ; the caller's stack pointer
        sub     r10, rax                ; its new stack pointer
        cmovb   r10, r11                ; (wrapped around: 0)
        mov     r11, gs:[10h]           ; TEB StackLimit
        cmp     r10, r11
        jae     done
        and     r10w, 0F000h
probe:
        lea     r11, [r11-1000h]
        mov     byte ptr [r11], 0
        cmp     r10, r11
        jne     probe
done:
        mov     r10, [rsp]
        mov     r11, [rsp+8]
        add     rsp, 10h
        ret
__chkstk ENDP

_TEXT ENDS

END
