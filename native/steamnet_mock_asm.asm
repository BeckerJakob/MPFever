; steamnet_mock.cpp's SteamAPI_SteamNetworkingMessage_t_Release, with the bytes of SDK 1.61's (rex.w jmp [rcx+0B8h], the
; message's m_pfnRelease), which mpf_steamnet.cpp checks before it turns Steam networking on

_TEXT SEGMENT

PUBLIC SteamAPI_SteamNetworkingMessage_t_Release

SteamAPI_SteamNetworkingMessage_t_Release PROC
        db 48h, 0FFh, 0A1h, 0B8h, 00h, 00h, 00h
SteamAPI_SteamNetworkingMessage_t_Release ENDP

_TEXT ENDS
END
