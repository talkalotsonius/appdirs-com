; APPDIRS.ASM
; 8086-compatible MS-DOS .COM utility.
;
; Usage:
;   APPDIRS <InputDirPath>
;       Writes the deterministic APPEND command to STDOUT.
;
;   APPDIRS <InputDirPath> <OutputDirPath>
;       Creates:
;         APPDIRS.BAT   - APPEND command
;         APPDIRS.LST   - qualifying directories, one per line
;         APPCMDS.IDX   - sorted COMMAND=FULLPATH command index
;         APPDCOLL.LOG  - rejected command-key assignments (collisions)
;
; Deterministic precedence:
;   1. Input root first, if it directly contains COM/EXE/BAT files.
;   2. Immediate application directories sorted case-insensitively using
;      natural alphanumeric order (APP2 before APP10).
;   3. For each application, APP\bin is processed before APP.  The emitted
;      suffix is always lowercase "\bin".
;   4. Within each qualifying directory: *.COM, then *.EXE, then *.BAT.
;   5. Filenames within each extension group use the same natural sort.
;   6. For each file, explicit key first (FOO.EXE), then extensionless key
;      (FOO).  First key assignment wins permanently.
;
; APPCMDS.IDX has no header/comments/blank lines and is sorted by key using
; the same case-insensitive natural comparator.
;
; Collision log format (one rejected assignment per line):
;   KEY KEEP=winning-full-path DROP=rejected-full-path
;
; Capacity limits are compile-time constants below.  Full command paths are
; spooled to APPCMDS.$$$ so the key table does not duplicate path strings.
;
; Build with Borland Turbo Assembler / Turbo Linker:
;   TASM APPDIRS.ASM
;   TLINK /Tde APPDIRS.OBJ,APPDIRS.COM
;

.MODEL TINY
.CODE
ORG 100h

MAXLINE     EQU 126
MAXARG      EQU 63
MAXPATH     EQU 96
MAXAPPS     EQU 128
MAXFILES    EQU 256
MAXKEYS     EQU 1024
NAMEREC     EQU 13                  ; 8.3 name (12 chars) + NUL
KEYREC      EQU 18                  ; key[13], pad, offset low/high
KEYOFF_LO   EQU 14
KEYOFF_HI   EQU 16

FK_NONE     EQU 0
FK_SCAN     EQU 1
FK_IO       EQU 2
FK_CAP      EQU 3
FK_LINE     EQU 4

CAP_APPS    EQU 1
CAP_FILES   EQU 2
CAP_KEYS    EQU 3

start:
        push    cs
        pop     ds
        cld

        ; Get PSP segment explicitly (DOS 3.0+).
        mov     ah, 62h
        int     21h
        mov     es, bx

        ; PSP command tail starts at ES:81h and ends with CR.
        mov     si, 81h
        mov     dx, 127

        ; Required argument 1: input/root directory.
        call    skip_spaces_psp
        jnc     arg1_present
        jmp     usage

arg1_present:
        mov     di, OFFSET rootbuf
        call    copy_arg_psp
        jnc     arg1_length_ok
        jmp     arg_too_long

arg1_length_ok:
        or      bx, bx
        jnz     have_root_arg
        jmp     usage

have_root_arg:
        mov     rootlen, bx
        mov     di, OFFSET rootbuf
        call    strip_trailing_slash
        mov     rootlen, bx

        ; Optional argument 2: output directory.  Omitted = STDOUT mode.
        call    skip_spaces_psp
        jnc     arg2_present

        mov     byte ptr filemode, 0
        push    ds
        pop     es
        jmp     validate_input

arg2_present:
        mov     di, OFFSET outbuf
        call    copy_arg_psp
        jnc     arg2_length_ok
        jmp     arg_too_long

arg2_length_ok:
        or      bx, bx
        jnz     have_out_arg
        jmp     usage

have_out_arg:
        mov     di, OFFSET outbuf
        call    strip_trailing_slash
        mov     outlen, bx

        ; Reject a third argument.
        call    skip_spaces_psp
        jc      no_extra_args
        jmp     usage

no_extra_args:
        mov     byte ptr filemode, 1
        push    ds
        pop     es

validate_input:
        mov     dx, OFFSET rootbuf
        mov     ax, 4300h
        int     21h
        jnc     root_attr_ok
        mov     errcode, ax
        jmp     root_error

root_attr_ok:
        test    cx, 10h
        jnz     root_is_dir
        jmp     root_not_dir

root_is_dir:
        cmp     byte ptr filemode, 0
        jne     validate_output
        jmp     setup_generation

validate_output:
        mov     dx, OFFSET outbuf
        mov     ax, 4300h
        int     21h
        jnc     out_attr_ok
        mov     errcode, ax
        jmp     out_error

out_attr_ok:
        test    cx, 10h
        jnz     out_is_dir
        jmp     out_not_dir

out_is_dir:
        call    build_output_paths

setup_generation:
        ; Initial APPEND line contains only the keyword.  Paths are appended
        ; after a directory is proven useful.
        mov     di, OFFSET linebuf
        mov     si, OFFSET prefix
        mov     cx, prefix_len
        rep     movsb
        mov     ax, di
        sub     ax, OFFSET linebuf
        mov     linelen, ax
        mov     byte ptr [di], 0
        mov     word ptr pathcount, 0

        mov     word ptr appcount, 0
        mov     word ptr keycount, 0
        mov     word ptr keynext, OFFSET keytable
        mov     word ptr spoolend_lo, 0
        mov     word ptr spoolend_hi, 0
        mov     byte ptr fatal_kind, FK_NONE
        mov     byte ptr cap_kind, 0

        ; Build ROOT\*.* and collect every immediate child directory before
        ; processing anything.  This breaks dependence on FAT directory order.
        call    build_parent_pattern
        call    collect_apps
        jnc     apps_collected
        jmp     fatal_from_call

apps_collected:
        mov     bx, OFFSET appnames
        mov     cx, appcount
        call    sort_name_records

        ; In file-output mode create only non-executable work outputs now.
        ; APPDIRS.BAT is deliberately delayed until scanning is finished so an
        ; output directory inside the input tree cannot introduce a new BAT.
        cmp     byte ptr filemode, 0
        je      process_root
        call    create_work_files
        jnc     process_root
        jmp     fatal_from_call

process_root:
        ; Root always has precedence over every application directory.
        mov     si, OFFSET rootbuf
        mov     cx, rootlen
        call    process_directory
        jnc     root_processed
        jmp     fatal_from_call

root_processed:
        ; Process naturally sorted application directory names.
        mov     ax, appcount
        mov     appremain, ax
        mov     word ptr appiter, OFFSET appnames

app_loop:
        cmp     word ptr appremain, 0
        jne     app_loop_have
        jmp     all_dirs_processed

app_loop_have:
        mov     si, appiter
        call    build_app_path

        ; APP\bin first, if it exists as a directory.
        call    build_bin_path
        mov     si, OFFSET binbuf
        mov     cx, binlen
        call    optional_dir_exists
        jnc     bin_check_ok
        jmp     fatal_from_call

bin_check_ok:
        or      al, al
        jz      app_root_phase
        mov     si, OFFSET binbuf
        mov     cx, binlen
        call    process_directory
        jnc     app_root_phase
        jmp     fatal_from_call

app_root_phase:
        ; Application root second.
        mov     si, OFFSET apppath
        mov     cx, apppathlen
        call    process_directory
        jnc     app_finished
        jmp     fatal_from_call

app_finished:
        add     word ptr appiter, NAMEREC
        dec     word ptr appremain
        jmp     app_loop

all_dirs_processed:
        ; If no path qualified, explicitly clear APPEND rather than emit bare
        ; APPEND (which displays the current setting).
        cmp     word ptr pathcount, 0
        jne     append_ready
        mov     ax, linelen
        cmp     ax, MAXLINE
        jb      append_clear_fits
        mov     byte ptr fatal_kind, FK_LINE
        jmp     fatal_from_call
append_clear_fits:
        mov     di, OFFSET linebuf
        add     di, linelen
        mov     byte ptr [di], ';'
        inc     di
        inc     word ptr linelen
        mov     byte ptr [di], 0

append_ready:
        cmp     byte ptr filemode, 0
        jne     finish_file_mode

        ; One-argument compatibility mode: APPEND command to STDOUT only.
        mov     bx, 1
        mov     dx, OFFSET linebuf
        mov     cx, linelen
        call    write_line
        jnc     stdout_success
        mov     errcode, ax
        jmp     stdout_write_error

stdout_success:
        mov     ax, 4C00h
        int     21h

finish_file_mode:
        ; APPDIRS.BAT is now safe to create: command discovery is complete.
        call    create_and_write_bat
        jnc     bat_finished
        jmp     fatal_from_call

bat_finished:
        ; LST and collision log were streamed in deterministic traversal order.
        call    close_lst_and_collision
        jnc     stream_outputs_closed
        jmp     fatal_from_call

stream_outputs_closed:
        ; Sort surviving keys independently of precedence.  Collision winners
        ; are already fixed; this sort is solely for lookup-friendly IDX output.
        call    build_and_sort_key_order

        call    create_and_write_index
        jnc     index_finished
        jmp     fatal_from_call

index_finished:
        ; Close spool and delete the temporary pathname store.
        mov     bx, spoolhandle
        cmp     bx, 0FFFFh
        je      spool_already_closed
        mov     ah, 3Eh
        int     21h
        jnc     spool_close_ok
        jmp     spool_close_failed
spool_close_ok:
        mov     word ptr spoolhandle, 0FFFFh

spool_already_closed:
        cmp     byte ptr tmpmade, 0
        je      final_success
        mov     dx, OFFSET tmppath
        mov     ah, 41h
        int     21h
        ; A failure to remove only the private temporary file is still treated
        ; as an error so successful runs leave exactly the documented outputs.
        jc      spool_delete_failed
        mov     byte ptr tmpmade, 0

final_success:
        mov     ax, 4C00h
        int     21h

spool_close_failed:
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     fatal_from_call

spool_delete_failed:
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     fatal_from_call

; ============================================================================
; Output path construction / work-file setup
; ============================================================================

build_output_paths PROC NEAR
        push    ax
        push    bx
        push    cx
        push    si
        push    di

        mov     si, OFFSET batname
        mov     cx, batname_len
        mov     di, OFFSET batpath
        call    make_output_path

        mov     si, OFFSET lstname
        mov     cx, lstname_len
        mov     di, OFFSET lstpath
        call    make_output_path

        mov     si, OFFSET idxname
        mov     cx, idxname_len
        mov     di, OFFSET idxpath
        call    make_output_path

        mov     si, OFFSET collname
        mov     cx, collname_len
        mov     di, OFFSET collpath
        call    make_output_path

        mov     si, OFFSET tmpname
        mov     cx, tmpname_len
        mov     di, OFFSET tmppath
        call    make_output_path

        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret
build_output_paths ENDP

; DS:SI filename, CX length, DS:DI destination.
make_output_path PROC NEAR
        push    ax
        push    bx
        push    cx
        push    si

        push    si
        push    cx
        mov     si, OFFSET outbuf
        mov     cx, outlen
        rep     movsb
        pop     cx
        pop     si

        mov     bx, outlen
        cmp     bx, 0
        je      mop_name
        dec     bx
        cmp     byte ptr outbuf[bx], '\'
        je      mop_name
        mov     al, '\'
        stosb
mop_name:
        rep     movsb
        xor     al, al
        stosb

        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret
make_output_path ENDP

create_work_files PROC NEAR
        ; APPDIRS.LST
        mov     dx, OFFSET lstpath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     cwf_lst_ok
        mov     errcode, ax
        mov     word ptr errorpath, OFFSET lstpath
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
cwf_lst_ok:
        mov     lsthandle, ax
        mov     byte ptr lstmade, 1

        ; APPDCOLL.LOG
        mov     dx, OFFSET collpath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     cwf_coll_ok
        mov     errcode, ax
        mov     word ptr errorpath, OFFSET collpath
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
cwf_coll_ok:
        mov     collhandle, ax
        mov     byte ptr collmade, 1

        ; APPCMDS.$$$ private pathname spool
        mov     dx, OFFSET tmppath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     cwf_tmp_ok
        mov     errcode, ax
        mov     word ptr errorpath, OFFSET tmppath
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
cwf_tmp_ok:
        mov     spoolhandle, ax
        mov     byte ptr tmpmade, 1
        clc
        ret
create_work_files ENDP

create_and_write_bat PROC NEAR
        mov     dx, OFFSET batpath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     cwb_created
        mov     errcode, ax
        mov     word ptr errorpath, OFFSET batpath
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret

cwb_created:
        mov     bathandle, ax
        mov     byte ptr batmade, 1
        mov     bx, ax
        mov     dx, OFFSET linebuf
        mov     cx, linelen
        call    write_line
        jnc     cwb_written
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret

cwb_written:
        mov     bx, bathandle
        mov     ah, 3Eh
        int     21h
        jnc     cwb_closed
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
cwb_closed:
        mov     word ptr bathandle, 0FFFFh
        clc
        ret
create_and_write_bat ENDP

close_lst_and_collision PROC NEAR
        mov     bx, lsthandle
        cmp     bx, 0FFFFh
        je      clc_lst_done
        mov     ah, 3Eh
        int     21h
        jnc     clc_lst_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
clc_lst_ok:
        mov     word ptr lsthandle, 0FFFFh
clc_lst_done:

        mov     bx, collhandle
        cmp     bx, 0FFFFh
        je      clc_coll_done
        mov     ah, 3Eh
        int     21h
        jnc     clc_coll_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        stc
        ret
clc_coll_ok:
        mov     word ptr collhandle, 0FFFFh
clc_coll_done:
        clc
        ret
close_lst_and_collision ENDP

; ============================================================================
; Deterministic application-directory collection
; ============================================================================

build_parent_pattern PROC NEAR
        push    ax
        push    bx
        push    cx
        push    si
        push    di

        mov     di, OFFSET parentpattern
        mov     si, OFFSET rootbuf
        mov     cx, rootlen
        rep     movsb

        mov     bx, rootlen
        cmp     bx, 0
        je      bpp_slash
        dec     bx
        cmp     byte ptr rootbuf[bx], '\'
        je      bpp_star
bpp_slash:
        mov     al, '\'
        stosb
bpp_star:
        mov     al, '*'
        stosb
        mov     al, '.'
        stosb
        mov     al, '*'
        stosb
        xor     al, al
        stosb

        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret
build_parent_pattern ENDP

collect_apps PROC NEAR
        mov     word ptr appcount, 0

        mov     dx, OFFSET dta
        mov     ah, 1Ah
        int     21h

        mov     dx, OFFSET parentpattern
        mov     cx, 17h                 ; R/H/S/D, no volume label
        mov     ah, 4Eh
        int     21h
        jc      ca_first_failed
        jmp     ca_found
ca_first_failed:
        cmp     ax, 0002h
        jne     ca_check_12_first
        jmp     ca_empty
ca_check_12_first:
        cmp     ax, 0012h
        jne     ca_first_error
        jmp     ca_empty
ca_first_error:
        mov     errcode, ax
        mov     word ptr scanpatternptr, OFFSET parentpattern
        mov     byte ptr fatal_kind, FK_SCAN
        stc
        ret

ca_found:
        test    byte ptr dta[15h], 10h
        jnz     ca_is_dir
        jmp     ca_next
ca_is_dir:
        mov     si, OFFSET dta + 1Eh
        call    is_dot_or_dotdot
        jnc     ca_not_dot
        jmp     ca_next
ca_not_dot:

        mov     ax, appcount
        cmp     ax, MAXAPPS
        jb      ca_room
        mov     byte ptr cap_kind, CAP_APPS
        mov     byte ptr fatal_kind, FK_CAP
        stc
        ret

ca_room:
        ; destination = appnames + appcount * NAMEREC
        mov     bx, NAMEREC
        mul     bx
        mov     di, OFFSET appnames
        add     di, ax
        mov     si, OFFSET dta + 1Eh
        call    copy_upper_name_record
        inc     word ptr appcount

ca_next:
        mov     ah, 4Fh
        int     21h
        jc      ca_next_failed
        jmp     ca_found
ca_next_failed:
        cmp     ax, 0012h
        jne     ca_next_error
        jmp     ca_empty
ca_next_error:
        mov     errcode, ax
        mov     word ptr scanpatternptr, OFFSET parentpattern
        mov     byte ptr fatal_kind, FK_SCAN
        stc
        ret

ca_empty:
        clc
        ret
collect_apps ENDP

; ============================================================================
; Candidate directory construction and processing
; ============================================================================

; DS:SI points to one sorted application name record.
build_app_path PROC NEAR
        push    ax
        push    bx
        push    cx
        push    si
        push    di

        mov     di, OFFSET apppath
        push    si
        mov     si, OFFSET rootbuf
        mov     cx, rootlen
        rep     movsb
        pop     si

        mov     bx, rootlen
        cmp     bx, 0
        je      bap_add_slash
        dec     bx
        cmp     byte ptr rootbuf[bx], '\'
        je      bap_name
bap_add_slash:
        mov     al, '\'
        stosb

bap_name:
        push    si
        call    asciiz_length
        rep     movsb
        pop     si
        mov     byte ptr [di], 0
        mov     ax, di
        sub     ax, OFFSET apppath
        mov     apppathlen, ax

        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret
build_app_path ENDP

build_bin_path PROC NEAR
        push    ax
        push    cx
        push    si
        push    di

        mov     di, OFFSET binbuf
        mov     si, OFFSET apppath
        mov     cx, apppathlen
        rep     movsb
        mov     si, OFFSET binsuffix
        mov     cx, binsuffix_len
        rep     movsb
        mov     byte ptr [di], 0
        mov     ax, di
        sub     ax, OFFSET binbuf
        mov     binlen, ax

        pop     di
        pop     si
        pop     cx
        pop     ax
        ret
build_bin_path ENDP

; DS:SI path, CX length.  Returns AL=1 if it exists and is a directory,
; AL=0 if absent/not a directory. CF=1 only for unexpected DOS errors.
optional_dir_exists PROC NEAR
        push    dx
        mov     dx, si
        mov     ax, 4300h
        int     21h
        jnc     ode_attr_ok

        cmp     ax, 0002h
        je      ode_absent
        cmp     ax, 0003h
        je      ode_absent
        mov     errcode, ax
        mov     word ptr scanpatternptr, si
        mov     byte ptr fatal_kind, FK_SCAN
        pop     dx
        stc
        ret

ode_attr_ok:
        test    cx, 10h
        jnz     ode_yes
ode_absent:
        xor     al, al
        pop     dx
        clc
        ret
ode_yes:
        mov     al, 1
        pop     dx
        clc
        ret
optional_dir_exists ENDP

; DS:SI path, CX length.  Scans COM/EXE/BAT in fixed order.  If at least one
; executable/script is present, appends the directory to APPEND/LST exactly
; once.  In file mode every file is also registered into the command index.
process_directory PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        ; Copy path into stable currentdir storage.
        mov     di, OFFSET currentdir
        mov     ax, cx
        mov     currentdirlen, ax
        rep     movsb
        mov     byte ptr [di], 0
        mov     byte ptr currentqualified, 0
        mov     byte ptr currentisout, 0

        ; Detect the exact output directory, case-insensitively, so an old
        ; APPDIRS.BAT there can be excluded from its own generated index.
        cmp     byte ptr filemode, 0
        je      pd_extensions
        mov     ax, currentdirlen
        cmp     ax, outlen
        jne     pd_extensions
        mov     si, OFFSET currentdir
        mov     di, OFFSET outbuf
        call    strings_equal_ci
        or      al, al
        jz      pd_extensions
        mov     byte ptr currentisout, 1

pd_extensions:
        ; COM
        mov     byte ptr extkind, 0
        mov     si, OFFSET ext_com
        call    process_extension
        jnc     pd_exe
        jmp     pd_error

pd_exe:
        mov     byte ptr extkind, 1
        mov     si, OFFSET ext_exe
        call    process_extension
        jnc     pd_bat
        jmp     pd_error

pd_bat:
        mov     byte ptr extkind, 2
        mov     si, OFFSET ext_bat
        call    process_extension
        jnc     pd_ok
        jmp     pd_error

pd_ok:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

pd_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
process_directory ENDP

; DS:SI points to a 3-byte extension string.  Collects and naturally sorts all
; matching files.  The first non-empty group qualifies currentdir.  In file
; mode sorted filenames are registered in precedence order.
process_extension PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        call    collect_extension
        jnc     pe_collected
        jmp     pe_error

pe_collected:
        cmp     word ptr filecount, 0
        jne     pe_nonempty
        jmp     pe_ok

pe_nonempty:
        cmp     byte ptr currentqualified, 0
        jne     pe_already_qualified
        call    add_current_directory
        jnc     pe_mark_qualified
        jmp     pe_error
pe_mark_qualified:
        mov     byte ptr currentqualified, 1

pe_already_qualified:
        cmp     byte ptr filemode, 0
        jne     pe_register
        jmp     pe_ok

pe_register:
        mov     ax, filecount
        mov     fileremain, ax
        mov     word ptr fileiter, OFFSET filenames

pe_register_loop:
        cmp     word ptr fileremain, 0
        jne     pe_have_file
        jmp     pe_ok

pe_have_file:
        mov     si, fileiter
        call    register_filename
        jnc     pe_registered
        jmp     pe_error
pe_registered:
        add     word ptr fileiter, NAMEREC
        dec     word ptr fileremain
        jmp     pe_register_loop

pe_ok:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

pe_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
process_extension ENDP

; Build currentdir\*.EXT, enumerate matching files into filenames[], sort them.
; DS:SI points to exactly three extension bytes.
collect_extension PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        ; Build pattern.
        mov     di, OFFSET filepattern
        push    si
        mov     si, OFFSET currentdir
        mov     cx, currentdirlen
        rep     movsb
        pop     si

        mov     bx, currentdirlen
        cmp     bx, 0
        je      ce_add_slash
        dec     bx
        cmp     byte ptr currentdir[bx], '\'
        je      ce_wild
ce_add_slash:
        mov     al, '\'
        stosb
ce_wild:
        mov     al, '*'
        stosb
        mov     al, '.'
        stosb
        mov     cx, 3
        rep     movsb
        xor     al, al
        stosb

        mov     word ptr filecount, 0

        mov     dx, OFFSET scandta
        mov     ah, 1Ah
        int     21h

        mov     dx, OFFSET filepattern
        mov     cx, 27h                 ; normal/R/H/S/A files, not dirs
        mov     ah, 4Eh
        int     21h
        jnc     ce_found

        cmp     ax, 0002h
        jne     ce_check_12_first
        jmp     ce_done_collect
ce_check_12_first:
        cmp     ax, 0012h
        jne     ce_first_error
        jmp     ce_done_collect
ce_first_error:
        mov     errcode, ax
        mov     word ptr scanpatternptr, OFFSET filepattern
        mov     byte ptr fatal_kind, FK_SCAN
        jmp     ce_error

ce_found:
        ; Defensive directory rejection even though CX excluded directories.
        test    byte ptr scandta[15h], 10h
        jz      ce_not_dir
        jmp     ce_next
ce_not_dir:

        ; If OutputDir itself is being scanned, ignore an old APPDIRS.BAT.
        cmp     byte ptr extkind, 2
        jne     ce_store
        cmp     byte ptr currentisout, 0
        je      ce_store
        mov     si, OFFSET scandta + 1Eh
        mov     di, OFFSET batname
        call    strings_equal_ci
        or      al, al
        jz      ce_store
        jmp     ce_next

ce_store:
        mov     ax, filecount
        cmp     ax, MAXFILES
        jb      ce_room
        mov     byte ptr cap_kind, CAP_FILES
        mov     byte ptr fatal_kind, FK_CAP
        jmp     ce_error

ce_room:
        mov     bx, NAMEREC
        mul     bx
        mov     di, OFFSET filenames
        add     di, ax
        mov     si, OFFSET scandta + 1Eh
        call    copy_upper_name_record
        inc     word ptr filecount

ce_next:
        mov     ah, 4Fh
        int     21h
        jc      ce_next_failed
        jmp     ce_found
ce_next_failed:
        cmp     ax, 0012h
        jne     ce_next_error
        jmp     ce_done_collect
ce_next_error:
        mov     errcode, ax
        mov     word ptr scanpatternptr, OFFSET filepattern
        mov     byte ptr fatal_kind, FK_SCAN
        jmp     ce_error

ce_done_collect:
        mov     bx, OFFSET filenames
        mov     cx, filecount
        call    sort_name_records

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

ce_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
collect_extension ENDP

; Add currentdir to the APPEND line and, in file mode, APPDIRS.LST.
add_current_directory PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     ax, linelen
        cmp     word ptr pathcount, 0
        je      acd_no_sep_size
        inc     ax
acd_no_sep_size:
        add     ax, currentdirlen
        cmp     ax, MAXLINE
        jbe     acd_fits
        mov     byte ptr fatal_kind, FK_LINE
        jmp     acd_error

acd_fits:
        mov     di, OFFSET linebuf
        add     di, linelen
        cmp     word ptr pathcount, 0
        je      acd_copy
        mov     byte ptr [di], ';'
        inc     di
acd_copy:
        mov     si, OFFSET currentdir
        mov     cx, currentdirlen
        rep     movsb
        mov     linelen, ax
        mov     byte ptr [di], 0
        inc     word ptr pathcount

        cmp     byte ptr filemode, 0
        je      acd_ok
        mov     bx, lsthandle
        mov     dx, OFFSET currentdir
        mov     cx, currentdirlen
        call    write_line
        jnc     acd_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     acd_error

acd_ok:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

acd_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
add_current_directory ENDP

; ============================================================================
; Command-key generation, first-wins collision handling, spool
; ============================================================================

; DS:SI -> sorted 8.3 filename record for currentdir.
register_filename PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        ; Build full executable pathname.
        mov     di, OFFSET fullpathbuf
        mov     bx, si                  ; preserve filename pointer
        mov     si, OFFSET currentdir
        mov     cx, currentdirlen
        rep     movsb

        mov     ax, currentdirlen
        cmp     ax, 0
        je      rf_add_slash
        mov     dx, bx                  ; preserve filename pointer
        mov     bx, ax
        dec     bx
        cmp     byte ptr currentdir[bx], '\'
        mov     bx, dx
        je      rf_filename
rf_add_slash:
        mov     al, '\'
        stosb
rf_filename:
        mov     si, bx
        call    asciiz_length
        rep     movsb
        mov     byte ptr [di], 0
        mov     ax, di
        sub     ax, OFFSET fullpathbuf
        mov     fullpathlen, ax
        mov     byte ptr currentstored, 0

        ; Explicit key first, e.g. FOO.EXE.
        mov     si, bx
        mov     di, OFFSET keywork
        call    clear_keywork
        call    copy_asciiz_to_keywork
        call    register_current_key
        jnc     rf_explicit_ok
        jmp     rf_error

rf_explicit_ok:
        ; Extensionless key second, e.g. FOO.
        mov     si, bx
        mov     di, OFFSET keywork
        call    clear_keywork
rf_base_loop:
        mov     al, [si]
        or      al, al
        jz      rf_base_done
        cmp     al, '.'
        je      rf_base_done
        mov     [di], al
        inc     di
        inc     si
        jmp     rf_base_loop
rf_base_done:
        mov     byte ptr [di], 0
        call    register_current_key
        jnc     rf_ok
        jmp     rf_error

rf_ok:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

rf_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
register_filename ENDP

clear_keywork PROC NEAR
        push    ax
        push    cx
        push    di
        xor     al, al
        mov     cx, 13
        rep     stosb
        pop     di
        pop     cx
        pop     ax
        ret
clear_keywork ENDP

; DS:SI ASCIZ -> keywork at DS:DI.  Caller has zero-filled keywork.
copy_asciiz_to_keywork PROC NEAR
        push    ax
        push    cx
        mov     cx, 12
cak_loop:
        mov     al, [si]
        or      al, al
        jz      cak_done
        mov     [di], al
        inc     si
        inc     di
        loop    cak_loop
cak_done:
        mov     byte ptr [di], 0
        pop     cx
        pop     ax
        ret
copy_asciiz_to_keywork ENDP

; Register keywork -> fullpathbuf.  Duplicate keys are logged and ignored.
; CF=1 only for I/O/capacity failure.
register_current_key PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        call    find_existing_key
        jnc     rck_new
        mov     duprecord, bx
        call    log_collision
        jc      rck_log_error
        jmp     rck_ok
rck_log_error:
        jmp     rck_error

rck_new:
        mov     ax, keycount
        cmp     ax, MAXKEYS
        jb      rck_capacity_ok
        mov     byte ptr cap_kind, CAP_KEYS
        mov     byte ptr fatal_kind, FK_CAP
        jmp     rck_error

rck_capacity_ok:
        cmp     byte ptr currentstored, 0
        jne     rck_have_path
        call    spool_current_path
        jnc     rck_have_path
        jmp     rck_error

rck_have_path:
        mov     di, keynext
        mov     si, OFFSET keywork
        mov     cx, 13
        rep     movsb
        mov     byte ptr [di], 0        ; pad byte at offset 13
        inc     di
        mov     ax, current_off_lo
        mov     [di], ax
        add     di, 2
        mov     ax, current_off_hi
        mov     [di], ax

        add     word ptr keynext, KEYREC
        inc     word ptr keycount

rck_ok:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

rck_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
register_current_key ENDP

; Search unsorted key table for keywork.  CF=1 and BX=record pointer if found.
find_existing_key PROC NEAR
        push    ax
        push    cx
        push    dx
        push    si
        push    di

        mov     cx, keycount
        mov     bx, OFFSET keytable
fek_loop:
        or      cx, cx
        jnz     fek_have_record
        jmp     fek_not_found
fek_have_record:
        mov     si, OFFSET keywork
        mov     di, bx
        mov     dx, 13
fek_cmp:
        mov     al, [si]
        cmp     al, [di]
        jne     fek_next
        inc     si
        inc     di
        dec     dx
        jnz     fek_cmp

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        stc
        ret

fek_next:
        add     bx, KEYREC
        dec     cx
        jmp     fek_loop

fek_not_found:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        clc
        ret
find_existing_key ENDP

; Store fullpathbuf once in APPCMDS.$$$ as [1-byte length][path bytes].
spool_current_path PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx

        mov     ax, spoolend_lo
        mov     current_off_lo, ax
        mov     ax, spoolend_hi
        mov     current_off_hi, ax

        mov     bx, spoolhandle
        mov     ax, 4200h               ; LSEEK absolute
        mov     cx, spoolend_hi
        mov     dx, spoolend_lo
        int     21h
        jnc     scp_seek_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     scp_error

scp_seek_ok:
        mov     ax, fullpathlen
        cmp     ax, 255
        jbe     scp_len_ok
        mov     byte ptr cap_kind, CAP_FILES
        mov     byte ptr fatal_kind, FK_CAP
        jmp     scp_error
scp_len_ok:
        mov     pathlenbyte, al

        mov     bx, spoolhandle
        mov     dx, OFFSET pathlenbyte
        mov     cx, 1
        call    write_exact
        jnc     scp_len_written
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     scp_error
scp_len_written:

        mov     bx, spoolhandle
        mov     dx, OFFSET fullpathbuf
        mov     cx, fullpathlen
        call    write_exact
        jnc     scp_path_written
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     scp_error

scp_path_written:
        mov     ax, fullpathlen
        inc     ax
        add     spoolend_lo, ax
        adc     word ptr spoolend_hi, 0
        mov     byte ptr currentstored, 1

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

scp_error:
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
spool_current_path ENDP

; duprecord points to winner.  Log keywork KEEP=winner DROP=current.
log_collision PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        mov     bx, duprecord
        call    read_record_path
        jnc     lc_have_winner
        jmp     lc_error

lc_have_winner:
        mov     si, OFFSET keywork
        call    asciiz_length
        mov     bx, collhandle
        mov     dx, OFFSET keywork
        call    write_exact
        jnc     lc_key_ok
        jmp     lc_write_fail
lc_key_ok:

        mov     bx, collhandle
        mov     dx, OFFSET keepsep
        mov     cx, keepsep_len
        call    write_exact
        jnc     lc_keepsep_ok
        jmp     lc_write_fail
lc_keepsep_ok:

        mov     bx, collhandle
        mov     dx, OFFSET winpathbuf
        mov     cx, winpathlen
        call    write_exact
        jnc     lc_win_ok
        jmp     lc_write_fail
lc_win_ok:

        mov     bx, collhandle
        mov     dx, OFFSET dropsep
        mov     cx, dropsep_len
        call    write_exact
        jnc     lc_dropsep_ok
        jmp     lc_write_fail
lc_dropsep_ok:

        mov     bx, collhandle
        mov     dx, OFFSET fullpathbuf
        mov     cx, fullpathlen
        call    write_line
        jnc     lc_ok

lc_write_fail:
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     lc_error

lc_ok:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

lc_error:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
log_collision ENDP

; BX = key-record pointer.  Reads its spooled path into winpathbuf/winpathlen.
read_record_path PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    di

        mov     cx, [bx+KEYOFF_HI]
        mov     dx, [bx+KEYOFF_LO]
        mov     bx, spoolhandle
        mov     ax, 4200h
        int     21h
        jnc     rrp_seek_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     rrp_error

rrp_seek_ok:
        mov     bx, spoolhandle
        mov     dx, OFFSET pathlenbyte
        mov     cx, 1
        call    read_exact
        jnc     rrp_len_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     rrp_error

rrp_len_ok:
        xor     ax, ax
        mov     al, pathlenbyte
        mov     winpathlen, ax
        mov     bx, spoolhandle
        mov     dx, OFFSET winpathbuf
        mov     cx, ax
        call    read_exact
        jnc     rrp_path_ok
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     rrp_error
rrp_path_ok:
        mov     di, OFFSET winpathbuf
        add     di, winpathlen
        mov     byte ptr [di], 0

        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

rrp_error:
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
read_record_path ENDP

; ============================================================================
; Final APPCMDS.IDX ordering and output
; ============================================================================

build_and_sort_key_order PROC NEAR
        push    ax
        push    bx
        push    cx
        push    di

        mov     ax, keycount
        mov     cx, ax
        mov     bx, OFFSET keytable
        mov     di, OFFSET keyorder
bko_fill:
        or      cx, cx
        jz      bko_sort
        mov     [di], bx
        add     di, 2
        add     bx, KEYREC
        dec     cx
        jmp     bko_fill

bko_sort:
        call    sort_key_pointers

        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret
build_and_sort_key_order ENDP

; Selection-sort keyorder[] by the key string each pointer references.
sort_key_pointers PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        mov     ax, keycount
        cmp     ax, 2
        jae     skp_need_sort
        jmp     skp_done
skp_need_sort:
        dec     ax
        mov     sort_outer_left, ax
        mov     word ptr sort_outer_ptr, OFFSET keyorder

skp_outer:
        mov     bx, sort_outer_ptr
        mov     ax, [bx]
        mov     sort_min_rec, ax
        mov     sort_min_slot, bx

        mov     cx, sort_outer_left
        mov     di, bx
        add     di, 2

skp_inner:
        mov     bx, [di]                ; candidate record
        mov     dx, sort_min_rec
        mov     si, bx
        mov     bp, di                  ; save candidate slot
        mov     di, dx
        call    natural_compare
        cmp     ax, 0FFFFh
        jne     skp_not_less
        mov     sort_min_rec, bx
        mov     sort_min_slot, bp
skp_not_less:
        mov     di, bp
        add     di, 2
        dec     cx
        jnz     skp_inner

        mov     bx, sort_outer_ptr
        mov     di, sort_min_slot
        cmp     bx, di
        je      skp_no_swap
        mov     ax, [bx]
        mov     dx, [di]
        mov     [bx], dx
        mov     [di], ax
skp_no_swap:
        add     word ptr sort_outer_ptr, 2
        dec     word ptr sort_outer_left
        jz      skp_done
        jmp     skp_outer

skp_done:
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
sort_key_pointers ENDP

create_and_write_index PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     dx, OFFSET idxpath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     cwi_created
        mov     errcode, ax
        mov     word ptr errorpath, OFFSET idxpath
        mov     byte ptr fatal_kind, FK_IO
        jmp     cwi_error

cwi_created:
        mov     idxhandle, ax
        mov     byte ptr idxmade, 1
        mov     ax, keycount
        mov     idxremain, ax
        mov     word ptr idxiter, OFFSET keyorder

cwi_loop:
        cmp     word ptr idxremain, 0
        jne     cwi_have
        jmp     cwi_close

cwi_have:
        mov     di, idxiter
        mov     bx, [di]                ; key-record pointer
        mov     current_idx_rec, bx

        mov     si, bx
        call    asciiz_length
        mov     bx, idxhandle
        mov     dx, si
        call    write_exact
        jnc     cwi_key_ok
        jmp     cwi_write_fail
cwi_key_ok:

        mov     bx, idxhandle
        mov     dx, OFFSET equalchar
        mov     cx, 1
        call    write_exact
        jnc     cwi_equal_ok
        jmp     cwi_write_fail
cwi_equal_ok:

        mov     bx, current_idx_rec
        call    read_record_path
        jnc     cwi_path_loaded
        jmp     cwi_error
cwi_path_loaded:

        mov     bx, idxhandle
        mov     dx, OFFSET winpathbuf
        mov     cx, winpathlen
        call    write_line
        jnc     cwi_line_ok
        jmp     cwi_write_fail

cwi_line_ok:
        add     word ptr idxiter, 2
        dec     word ptr idxremain
        jmp     cwi_loop

cwi_write_fail:
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     cwi_error

cwi_close:
        mov     bx, idxhandle
        mov     ah, 3Eh
        int     21h
        jnc     cwi_closed
        mov     errcode, ax
        mov     byte ptr fatal_kind, FK_IO
        jmp     cwi_error
cwi_closed:
        mov     word ptr idxhandle, 0FFFFh

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

cwi_error:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc
        ret
create_and_write_index ENDP

; ============================================================================
; Deterministic natural sorting
; ============================================================================

; Selection sort fixed 13-byte ASCIZ name records.
; Input BX = base address, CX = count.
sort_name_records PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        cmp     cx, 2
        jae     snr_need_sort
        jmp     snr_done
snr_need_sort:
        dec     cx
        mov     sort_outer_left, cx
        mov     sort_outer_ptr, bx

snr_outer:
        mov     bx, sort_outer_ptr
        mov     sort_min_slot, bx
        mov     ax, sort_outer_left
        mov     dx, ax
        mov     di, bx
        add     di, NAMEREC

snr_inner:
        mov     si, di
        mov     bp, sort_min_slot
        mov     di, bp
        call    natural_compare
        cmp     ax, 0FFFFh
        jne     snr_not_less
        mov     sort_min_slot, si
snr_not_less:
        mov     di, si
        add     di, NAMEREC
        dec     dx
        jnz     snr_inner

        mov     si, sort_outer_ptr
        mov     di, sort_min_slot
        cmp     si, di
        je      snr_no_swap
        mov     cx, NAMEREC
        call    swap_bytes
snr_no_swap:
        add     word ptr sort_outer_ptr, NAMEREC
        dec     word ptr sort_outer_left
        jz      snr_done
        jmp     snr_outer

snr_done:
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
sort_name_records ENDP

; Natural case-insensitive ASCII comparison.
; DS:SI = A, DS:DI = B, both ASCIZ.
; AX = FFFFh if A<B, 0000h if equal, 0001h if A>B.
; Numeric runs compare by numeric magnitude; equal values use shorter digit run
; first (APP2 < APP02 < APP002).  Non-alphanumerics use uppercase byte order.
natural_compare PROC NEAR
        push    bx
        push    cx
        push    dx
        push    si
        push    di

nc_loop:
        mov     al, [si]
        mov     bl, [di]
        call    uppercase_al
        xchg    al, bl
        call    uppercase_al
        xchg    al, bl                  ; AL=A upper, BL=B upper

        ; Both digits => compare complete numeric runs.
        cmp     al, '0'
        jb      nc_not_both_digits
        cmp     al, '9'
        ja      nc_not_both_digits
        cmp     bl, '0'
        jb      nc_not_both_digits
        cmp     bl, '9'
        ja      nc_not_both_digits
        jmp     nc_digit_runs

nc_not_both_digits:
        or      al, al
        jnz     nc_a_not_end
        or      bl, bl
        jz      nc_both_end
        jmp     nc_less
nc_both_end:
        xor     ax, ax
        jmp     nc_return
nc_a_not_end:
        or      bl, bl
        jnz     nc_compare_chars
        jmp     nc_greater
nc_compare_chars:
        cmp     al, bl
        jae     nc_chars_not_less
        jmp     nc_less
nc_chars_not_less:
        je      nc_chars_equal
        jmp     nc_greater
nc_chars_equal:
        inc     si
        inc     di
        jmp     nc_loop

nc_digit_runs:
        ; Find end of A digit run.
        mov     bx, si
nc_a_end_loop:
        mov     al, [bx]
        cmp     al, '0'
        jb      nc_a_end_found
        cmp     al, '9'
        ja      nc_a_end_found
        inc     bx
        jmp     nc_a_end_loop
nc_a_end_found:
        mov     nat_a_end, bx
        mov     ax, bx
        sub     ax, si
        mov     nat_a_runlen, ax

        ; Find first non-zero significant A digit.
        mov     bx, si
nc_a_zero_loop:
        cmp     bx, nat_a_end
        jae     nc_a_all_zero
        cmp     byte ptr [bx], '0'
        jne     nc_a_sig_found
        inc     bx
        jmp     nc_a_zero_loop
nc_a_all_zero:
        mov     ax, nat_a_end
        mov     nat_a_sig, ax
        mov     word ptr nat_a_siglen, 0
        jmp     nc_scan_b
nc_a_sig_found:
        mov     nat_a_sig, bx
        mov     ax, nat_a_end
        sub     ax, bx
        mov     nat_a_siglen, ax

nc_scan_b:
        mov     bx, di
nc_b_end_loop:
        mov     al, [bx]
        cmp     al, '0'
        jb      nc_b_end_found
        cmp     al, '9'
        ja      nc_b_end_found
        inc     bx
        jmp     nc_b_end_loop
nc_b_end_found:
        mov     nat_b_end, bx
        mov     ax, bx
        sub     ax, di
        mov     nat_b_runlen, ax

        mov     bx, di
nc_b_zero_loop:
        cmp     bx, nat_b_end
        jae     nc_b_all_zero
        cmp     byte ptr [bx], '0'
        jne     nc_b_sig_found
        inc     bx
        jmp     nc_b_zero_loop
nc_b_all_zero:
        mov     ax, nat_b_end
        mov     nat_b_sig, ax
        mov     word ptr nat_b_siglen, 0
        jmp     nc_compare_numeric
nc_b_sig_found:
        mov     nat_b_sig, bx
        mov     ax, nat_b_end
        sub     ax, bx
        mov     nat_b_siglen, ax

nc_compare_numeric:
        mov     ax, nat_a_siglen
        cmp     ax, nat_b_siglen
        jae     nc_num_not_less
        jmp     nc_less
nc_num_not_less:
        je      nc_num_same_len
        jmp     nc_greater
nc_num_same_len:
        or      ax, ax
        jnz     nc_num_has_digits
        jmp     nc_numeric_equal
nc_num_has_digits:
        mov     si, nat_a_sig
        mov     di, nat_b_sig
        mov     cx, nat_a_siglen
nc_sig_loop:
        mov     al, [si]
        cmp     al, [di]
        jae     nc_sig_not_less
        jmp     nc_less
nc_sig_not_less:
        je      nc_sig_equal_digit
        jmp     nc_greater
nc_sig_equal_digit:
        inc     si
        inc     di
        loop    nc_sig_loop

nc_numeric_equal:
        ; Same numeric value: shorter original digit run first.
        mov     ax, nat_a_runlen
        cmp     ax, nat_b_runlen
        jb      nc_less
        ja      nc_greater

        mov     si, nat_a_end
        mov     di, nat_b_end
        jmp     nc_loop

nc_less:
        mov     ax, 0FFFFh
        jmp     nc_return
nc_greater:
        mov     ax, 1
nc_return:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret
natural_compare ENDP

uppercase_al PROC NEAR
        cmp     al, 'a'
        jb      uca_done
        cmp     al, 'z'
        ja      uca_done
        sub     al, 20h
uca_done:
        ret
uppercase_al ENDP

; Swap CX bytes at DS:SI and DS:DI.  Preserves pointers/count.
swap_bytes PROC NEAR
        push    ax
        push    cx
        push    si
        push    di
sb_loop:
        mov     al, [si]
        xchg    al, [di]
        mov     [si], al
        inc     si
        inc     di
        loop    sb_loop
        pop     di
        pop     si
        pop     cx
        pop     ax
        ret
swap_bytes ENDP

; ============================================================================
; String / PSP helpers
; ============================================================================

; Skip spaces/tabs. CF=1 if CR/end reached before an argument.
skip_spaces_psp PROC NEAR
ssp_loop:
        or      dx, dx
        jnz     ssp_have
        stc
        ret
ssp_have:
        mov     al, es:[si]
        cmp     al, 0Dh
        jne     ssp_not_cr
        stc
        ret
ssp_not_cr:
        cmp     al, ' '
        je      ssp_advance
        cmp     al, 9
        je      ssp_advance
        clc
        ret
ssp_advance:
        inc     si
        dec     dx
        jmp     ssp_loop
skip_spaces_psp ENDP

; Copy one whitespace-delimited PSP argument to DS:DI.
; Uppercases ASCII a-z. BX returns length. CF=1 if > MAXARG.
copy_arg_psp PROC NEAR
        xor     bx, bx
cap_loop:
        or      dx, dx
        jnz     cap_have
        jmp     cap_done
cap_have:
        mov     al, es:[si]
        cmp     al, 0Dh
        jne     cap_not_cr
        jmp     cap_done
cap_not_cr:
        cmp     al, ' '
        jne     cap_not_space
        jmp     cap_done
cap_not_space:
        cmp     al, 9
        jne     cap_not_tab
        jmp     cap_done
cap_not_tab:
        cmp     bx, MAXARG
        jb      cap_room
        stc
        ret
cap_room:
        cmp     al, 'a'
        jb      cap_store
        cmp     al, 'z'
        ja      cap_store
        sub     al, 20h
cap_store:
        mov     [di], al
        inc     di
        inc     bx
        inc     si
        dec     dx
        jmp     cap_loop
cap_done:
        mov     byte ptr [di], 0
        clc
        ret
copy_arg_psp ENDP

; DS:DI buffer, BX current length.  Strip a trailing slash except for X:\.
strip_trailing_slash PROC NEAR
        push    ax
        push    si
        cmp     bx, 3
        jbe     sts_done
        mov     ax, bx
        dec     ax
        mov     si, di
        add     si, ax
        cmp     byte ptr [si], '\'
        jne     sts_done
        mov     byte ptr [si], 0
        dec     bx
sts_done:
        pop     si
        pop     ax
        ret
strip_trailing_slash ENDP

; Copy DS:SI ASCIZ DOS name into 13-byte DS:DI record, uppercase and zero-pad.
copy_upper_name_record PROC NEAR
        push    ax
        push    cx
        push    si
        push    di

        push    si
        push    di
        xor     al, al
        mov     cx, NAMEREC
        rep     stosb
        pop     di
        pop     si

        mov     cx, 12
cun_loop:
        mov     al, [si]
        or      al, al
        jz      cun_done
        call    uppercase_al
        mov     [di], al
        inc     si
        inc     di
        loop    cun_loop
cun_done:
        mov     byte ptr [di], 0

        pop     di
        pop     si
        pop     cx
        pop     ax
        ret
copy_upper_name_record ENDP

; DS:SI -> ASCIZ, returns length in CX. Preserves SI.
asciiz_length PROC NEAR
        push    si
        xor     cx, cx
al_loop:
        cmp     byte ptr [si], 0
        je      al_done
        inc     si
        inc     cx
        jmp     al_loop
al_done:
        pop     si
        ret
asciiz_length ENDP

; Case-insensitive equality. DS:SI A, DS:DI B. AL=1 equal, 0 otherwise.
strings_equal_ci PROC NEAR
        push    bx
        push    si
        push    di
seci_loop:
        mov     al, [si]
        mov     bl, [di]
        call    uppercase_al
        xchg    al, bl
        call    uppercase_al
        xchg    al, bl
        cmp     al, bl
        jne     seci_no
        or      al, al
        jz      seci_yes
        inc     si
        inc     di
        jmp     seci_loop
seci_no:
        xor     al, al
        jmp     seci_return
seci_yes:
        mov     al, 1
seci_return:
        pop     di
        pop     si
        pop     bx
        ret
strings_equal_ci ENDP

; DS:SI points at DTA filename. CF=1 for "." or ".."; otherwise CF=0.
is_dot_or_dotdot PROC NEAR
        cmp     byte ptr [si], '.'
        je      idd_starts_dot
        clc
        ret
idd_starts_dot:
        cmp     byte ptr [si+1], 0
        je      idd_yes
        cmp     byte ptr [si+1], '.'
        je      idd_second_dot
        clc
        ret
idd_second_dot:
        cmp     byte ptr [si+2], 0
        je      idd_yes
        clc
        ret
idd_yes:
        stc
        ret
is_dot_or_dotdot ENDP

; ============================================================================
; DOS file I/O helpers
; ============================================================================

; Write exactly CX bytes from DS:DX to handle BX.
; CF=0 success. CF=1 error; AX is DOS error or 0005h on short write.
write_exact PROC NEAR
        push    cx
        mov     ah, 40h
        int     21h
        jc      we_dos_error
        pop     cx
        cmp     ax, cx
        je      we_ok
        mov     ax, 0005h
        stc
        ret
we_dos_error:
        pop     cx
        stc
        ret
we_ok:
        clc
        ret
write_exact ENDP

; Read exactly CX bytes into DS:DX from handle BX.
; EOF/short read is reported as error 0005h because spool records are internal.
read_exact PROC NEAR
        push    cx
        mov     ah, 3Fh
        int     21h
        jc      re_dos_error
        pop     cx
        cmp     ax, cx
        je      re_ok
        mov     ax, 0005h
        stc
        ret
re_dos_error:
        pop     cx
        stc
        ret
re_ok:
        clc
        ret
read_exact ENDP

; Write DS:DX[CX] plus CR/LF to handle BX.
write_line PROC NEAR
        call    write_exact
        jnc     wl_text_ok
        ret
wl_text_ok:
        mov     dx, OFFSET crlf
        mov     cx, 2
        call    write_exact
        ret
write_line ENDP

; ============================================================================
; Error handling / transactional cleanup
; ============================================================================

fatal_from_call:
        cmp     byte ptr filemode, 0
        je      fatal_no_cleanup
        call    cleanup_outputs
fatal_no_cleanup:
        cmp     byte ptr fatal_kind, FK_LINE
        jne     fatal_check_cap
        jmp     line_too_long
fatal_check_cap:
        cmp     byte ptr fatal_kind, FK_CAP
        jne     fatal_check_scan
        jmp     capacity_error
fatal_check_scan:
        cmp     byte ptr fatal_kind, FK_SCAN
        jne     fatal_io
        jmp     scan_error
fatal_io:
        jmp     io_error

usage:
        mov     dx, OFFSET msg_usage
        mov     cx, msg_usage_len
        mov     al, 1
        jmp     stderr_exit

arg_too_long:
        mov     dx, OFFSET msg_arglong
        mov     cx, msg_arglong_len
        mov     al, 2
        jmp     stderr_exit

line_too_long:
        mov     dx, OFFSET msg_toolong
        mov     cx, msg_toolong_len
        mov     al, 3
        jmp     stderr_exit

root_error:
        mov     dx, OFFSET msg_rooterr
        mov     cx, msg_rooterr_len
        call    write_stderr
        mov     dx, OFFSET rootbuf
        call    write_asciiz_stderr
        call    write_crlf_stderr
        call    write_error_code
        mov     al, 4
        jmp     exit_with_al

root_not_dir:
        mov     dx, OFFSET msg_rootnotdir
        mov     cx, msg_rootnotdir_len
        call    write_stderr
        mov     dx, OFFSET rootbuf
        call    write_asciiz_stderr
        call    write_crlf_stderr
        mov     al, 4
        jmp     exit_with_al

out_error:
        mov     dx, OFFSET msg_outerr
        mov     cx, msg_outerr_len
        call    write_stderr
        mov     dx, OFFSET outbuf
        call    write_asciiz_stderr
        call    write_crlf_stderr
        call    write_error_code
        mov     al, 5
        jmp     exit_with_al

out_not_dir:
        mov     dx, OFFSET msg_outnotdir
        mov     cx, msg_outnotdir_len
        call    write_stderr
        mov     dx, OFFSET outbuf
        call    write_asciiz_stderr
        call    write_crlf_stderr
        mov     al, 5
        jmp     exit_with_al

scan_error:
        mov     dx, OFFSET msg_scan
        mov     cx, msg_scan_len
        call    write_stderr
        mov     dx, OFFSET msg_pattern
        mov     cx, msg_pattern_len
        call    write_stderr
        mov     dx, scanpatternptr
        call    write_asciiz_stderr
        call    write_crlf_stderr
        call    write_error_code
        mov     al, 6
        jmp     exit_with_al

capacity_error:
        mov     dx, OFFSET msg_capacity
        mov     cx, msg_capacity_len
        call    write_stderr
        cmp     byte ptr cap_kind, CAP_APPS
        jne     cap_not_apps
        mov     dx, OFFSET msg_cap_apps
        mov     cx, msg_cap_apps_len
        jmp     cap_emit
cap_not_apps:
        cmp     byte ptr cap_kind, CAP_FILES
        jne     cap_keys_case
        mov     dx, OFFSET msg_cap_files
        mov     cx, msg_cap_files_len
        jmp     cap_emit
cap_keys_case:
        mov     dx, OFFSET msg_cap_keys
        mov     cx, msg_cap_keys_len
cap_emit:
        call    write_stderr
        mov     al, 7
        jmp     exit_with_al

io_error:
        mov     dx, OFFSET msg_io
        mov     cx, msg_io_len
        call    write_stderr
        call    write_error_code
        mov     al, 8
        jmp     exit_with_al

stdout_write_error:
        mov     dx, OFFSET msg_stdoutwrite
        mov     cx, msg_stdoutwrite_len
        call    write_stderr
        call    write_error_code
        mov     al, 9
        jmp     exit_with_al

; Close open handles and delete only files created/truncated by this run.
cleanup_outputs PROC NEAR
        push    ax
        push    bx
        push    dx

        mov     bx, bathandle
        cmp     bx, 0FFFFh
        je      co_bat_closed
        mov     ah, 3Eh
        int     21h
        mov     word ptr bathandle, 0FFFFh
co_bat_closed:

        mov     bx, lsthandle
        cmp     bx, 0FFFFh
        je      co_lst_closed
        mov     ah, 3Eh
        int     21h
        mov     word ptr lsthandle, 0FFFFh
co_lst_closed:

        mov     bx, idxhandle
        cmp     bx, 0FFFFh
        je      co_idx_closed
        mov     ah, 3Eh
        int     21h
        mov     word ptr idxhandle, 0FFFFh
co_idx_closed:

        mov     bx, collhandle
        cmp     bx, 0FFFFh
        je      co_coll_closed
        mov     ah, 3Eh
        int     21h
        mov     word ptr collhandle, 0FFFFh
co_coll_closed:

        mov     bx, spoolhandle
        cmp     bx, 0FFFFh
        je      co_tmp_closed
        mov     ah, 3Eh
        int     21h
        mov     word ptr spoolhandle, 0FFFFh
co_tmp_closed:

        cmp     byte ptr batmade, 0
        je      co_no_bat
        mov     dx, OFFSET batpath
        mov     ah, 41h
        int     21h
        mov     byte ptr batmade, 0
co_no_bat:
        cmp     byte ptr lstmade, 0
        je      co_no_lst
        mov     dx, OFFSET lstpath
        mov     ah, 41h
        int     21h
        mov     byte ptr lstmade, 0
co_no_lst:
        cmp     byte ptr idxmade, 0
        je      co_no_idx
        mov     dx, OFFSET idxpath
        mov     ah, 41h
        int     21h
        mov     byte ptr idxmade, 0
co_no_idx:
        cmp     byte ptr collmade, 0
        je      co_no_coll
        mov     dx, OFFSET collpath
        mov     ah, 41h
        int     21h
        mov     byte ptr collmade, 0
co_no_coll:
        cmp     byte ptr tmpmade, 0
        je      co_done
        mov     dx, OFFSET tmppath
        mov     ah, 41h
        int     21h
        mov     byte ptr tmpmade, 0
co_done:
        pop     dx
        pop     bx
        pop     ax
        ret
cleanup_outputs ENDP

; Print "DOS error AX=XXXXh" to STDERR using errcode.
write_error_code PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx

        mov     dx, OFFSET msg_doserr
        mov     cx, msg_doserr_len
        call    write_stderr

        mov     ax, errcode

        mov     dl, ah
        mov     cl, 4
        shr     dl, cl
        call    write_hex_nibble

        mov     dl, ah
        and     dl, 0Fh
        call    write_hex_nibble

        mov     dl, al
        mov     cl, 4
        shr     dl, cl
        call    write_hex_nibble

        mov     dl, al
        and     dl, 0Fh
        call    write_hex_nibble

        mov     dx, OFFSET msg_hexend
        mov     cx, msg_hexend_len
        call    write_stderr

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
write_error_code ENDP

write_hex_nibble PROC NEAR
        push    ax
        push    cx
        push    dx
        and     dl, 0Fh
        cmp     dl, 9
        jbe     whn_digit
        add     dl, 'A' - 10
        jmp     whn_emit
whn_digit:
        add     dl, '0'
whn_emit:
        mov     hexchar, dl
        mov     dx, OFFSET hexchar
        mov     cx, 1
        call    write_stderr
        pop     dx
        pop     cx
        pop     ax
        ret
write_hex_nibble ENDP

write_stderr PROC NEAR
        push    ax
        push    bx
        mov     bx, 2
        mov     ah, 40h
        int     21h
        pop     bx
        pop     ax
        ret
write_stderr ENDP

write_asciiz_stderr PROC NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     si, dx
        call    asciiz_length
        mov     bx, 2
        mov     ah, 40h
        int     21h
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
write_asciiz_stderr ENDP

write_crlf_stderr PROC NEAR
        push    cx
        push    dx
        mov     dx, OFFSET crlf
        mov     cx, 2
        call    write_stderr
        pop     dx
        pop     cx
        ret
write_crlf_stderr ENDP

stderr_exit:
        push    ax
        call    write_stderr
        pop     ax

exit_with_al:
        mov     ah, 4Ch
        int     21h

; ============================================================================
; Data
; ============================================================================

prefix          db 'APPEND '
prefix_len      EQU $ - prefix
binsuffix       db '\bin'
binsuffix_len   EQU $ - binsuffix
ext_com         db 'COM'
ext_exe         db 'EXE'
ext_bat         db 'BAT'

batname         db 'APPDIRS.BAT'
batname_len     EQU $ - batname
lstname         db 'APPDIRS.LST'
lstname_len     EQU $ - lstname
idxname         db 'APPCMDS.IDX'
idxname_len     EQU $ - idxname
collname        db 'APPDCOLL.LOG'
collname_len    EQU $ - collname
tmpname         db 'APPCMDS.$$$'
tmpname_len     EQU $ - tmpname

keepsep         db ' KEEP='
keepsep_len     EQU $ - keepsep
dropsep         db ' DROP='
dropsep_len     EQU $ - dropsep
equalchar       db '='
crlf            db 13,10
hexchar         db 0

msg_usage       db 'Usage: APPDIRS <InputDirPath> [OutputDirPath]',13,10
msg_usage_len   EQU $ - msg_usage
msg_arglong     db 'APPDIRS: an argument is too long.',13,10
msg_arglong_len EQU $ - msg_arglong
msg_toolong     db 'APPDIRS: APPEND command exceeds DOS 126-character limit.',13,10
msg_toolong_len EQU $ - msg_toolong
msg_rooterr     db 'APPDIRS: input directory cannot be accessed: '
msg_rooterr_len EQU $ - msg_rooterr
msg_rootnotdir  db 'APPDIRS: input path is not a directory: '
msg_rootnotdir_len EQU $ - msg_rootnotdir
msg_outerr      db 'APPDIRS: output directory cannot be accessed: '
msg_outerr_len  EQU $ - msg_outerr
msg_outnotdir   db 'APPDIRS: output path is not a directory: '
msg_outnotdir_len EQU $ - msg_outnotdir
msg_scan        db 'APPDIRS: directory/file enumeration failed.',13,10
msg_scan_len    EQU $ - msg_scan
msg_pattern     db 'Search path/pattern: '
msg_pattern_len EQU $ - msg_pattern
msg_capacity    db 'APPDIRS: compile-time capacity exceeded: '
msg_capacity_len EQU $ - msg_capacity
msg_cap_apps    db 'too many application directories.',13,10
msg_cap_apps_len EQU $ - msg_cap_apps
msg_cap_files   db 'too many executable files in one extension group.',13,10
msg_cap_files_len EQU $ - msg_cap_files
msg_cap_keys    db 'too many unique command keys.',13,10
msg_cap_keys_len EQU $ - msg_cap_keys
msg_io          db 'APPDIRS: output/index temporary-file I/O failed.',13,10
msg_io_len      EQU $ - msg_io
msg_stdoutwrite db 'APPDIRS: STDOUT write failed.',13,10
msg_stdoutwrite_len EQU $ - msg_stdoutwrite
msg_doserr      db 'DOS error AX='
msg_doserr_len  EQU $ - msg_doserr
msg_hexend      db 'h',13,10
msg_hexend_len  EQU $ - msg_hexend

rootlen         dw 0
outlen          dw 0
linelen         dw 0
pathcount       dw 0
appcount        dw 0
filecount       dw 0
keycount        dw 0
apppathlen      dw 0
binlen          dw 0
currentdirlen   dw 0
fullpathlen     dw 0
winpathlen      dw 0

appiter         dw 0
appremain       dw 0
fileiter        dw 0
fileremain      dw 0
keynext         dw 0
idxiter         dw 0
idxremain       dw 0
current_idx_rec dw 0

duprecord       dw 0
current_off_lo  dw 0
current_off_hi  dw 0
spoolend_lo     dw 0
spoolend_hi     dw 0

errcode         dw 0
scanpatternptr  dw 0
errorpath       dw 0
fatal_kind      db 0
cap_kind        db 0
filemode        db 0                  ; 0 = STDOUT, 1 = generate files
extkind         db 0                  ; 0 COM, 1 EXE, 2 BAT
currentqualified db 0
currentisout    db 0
currentstored   db 0
pathlenbyte     db 0

bathandle       dw 0FFFFh
lsthandle       dw 0FFFFh
idxhandle       dw 0FFFFh
collhandle      dw 0FFFFh
spoolhandle     dw 0FFFFh
batmade         db 0
lstmade         db 0
idxmade         db 0
collmade        db 0
tmpmade         db 0

; Natural-comparison scratch.
nat_a_end       dw 0
nat_b_end       dw 0
nat_a_sig       dw 0
nat_b_sig       dw 0
nat_a_runlen    dw 0
nat_b_runlen    dw 0
nat_a_siglen    dw 0
nat_b_siglen    dw 0

; Sort scratch.
sort_outer_left dw 0
sort_outer_ptr  dw 0
sort_min_slot   dw 0
sort_min_rec    dw 0

rootbuf         db MAXARG+1 dup (0)
outbuf          db MAXARG+1 dup (0)
parentpattern   db MAXPATH+8 dup (0)
filepattern     db MAXPATH+8 dup (0)

batpath         db MAXPATH dup (0)
lstpath         db MAXPATH dup (0)
idxpath         db MAXPATH dup (0)
collpath        db MAXPATH dup (0)
tmppath         db MAXPATH dup (0)

linebuf         db MAXLINE+1 dup (0)
apppath         db MAXPATH dup (0)
binbuf          db MAXPATH dup (0)
currentdir      db MAXPATH dup (0)
fullpathbuf     db MAXPATH dup (0)
winpathbuf      db MAXPATH dup (0)
keywork         db 13 dup (0)

dta             db 43 dup (0)
scandta         db 43 dup (0)

; Fixed-capacity deterministic catalogs.
appnames        db (MAXAPPS*NAMEREC) dup (0)
filenames       db (MAXFILES*NAMEREC) dup (0)
keyorder        dw MAXKEYS dup (0)
keytable        db (MAXKEYS*KEYREC) dup (0)

END start
