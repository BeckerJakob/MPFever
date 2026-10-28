; the square root of mpf_math.cpp (the SSE2 instruction: correctly rounded on every processor); no compiler header needed
.code
mpf_sqrt PROC
    sqrtsd xmm0, xmm0
    ret
mpf_sqrt ENDP
END
