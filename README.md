# APPDIRS.COM

APPDIRS.COM is an 8086-compatible MS-DOS utility that scans an application
directory tree and generates a deterministic `APPEND` search path. It can also
write directory and command indexes for use by DOS shells and launchers such as
4DOS.

## Building

This repository does not include a prebuilt binary. Build `APPDIRS.COM` from
the supplied assembly source before using it.

The build requires Borland Turbo Assembler (`TASM`) and Turbo Linker (`TLINK`)
available on `PATH` in a DOS-compatible environment.

From the repository root, run:

```dos
BUILD.BAT
```

The executable is written to `BUILD\APPDIRS.COM`. Build logs are written under
`BUILD\LOG`.

Equivalent assembler and linker commands are:

```dos
TASM SRC\APPDIRS.ASM,BUILD\APPDIRS.OBJ,BUILD\APPDIRS.LST
TLINK /Tde BUILD\APPDIRS.OBJ,BUILD\APPDIRS.COM
```

## Usage

```dos
APPDIRS <InputDirPath> [OutputDirPath]
```

Paths containing spaces are not supported. Both arguments must name existing
directories.

### Print an APPEND command

With one argument, APPDIRS writes the generated command to standard output:

```dos
APPDIRS D:\APPS
```

Example output:

```dos
APPEND D:\APPS\EDITOR\bin;D:\APPS\EDITOR;D:\APPS\TOOLS
```

This output can be redirected to a batch file:

```dos
APPDIRS D:\APPS > SETAPPS.BAT
```

If no directory contains a supported command file, the utility emits
`APPEND ;`, which clears the current APPEND setting.

### Generate index files

With an output directory, APPDIRS creates four files there:

```dos
APPDIRS D:\APPS D:\CONFIG
```

| File | Contents |
| --- | --- |
| `APPDIRS.BAT` | The generated `APPEND` command. |
| `APPDIRS.LST` | Qualifying directories, one per line, in precedence order. |
| `APPCMDS.IDX` | Sorted `COMMAND=FULLPATH` entries for discovered commands. |
| `APPDCOLL.LOG` | Rejected command-key assignments caused by collisions. |

`APPCMDS.IDX` registers both the filename and its extensionless alias. For
example, `EDIT.EXE` produces keys for `EDIT.EXE` and `EDIT`. The index contains
no header, comments, or blank lines.

Collision records have this format:

```text
KEY KEEP=winning-full-path DROP=rejected-full-path
```

The first assignment to a key wins. `APPDCOLL.LOG` is empty when there are no
collisions. Output creation is transactional: files created or truncated by a
failed run are removed.

## Directory scanning

APPDIRS examines these locations only:

1. The input directory itself.
2. Every immediate child directory of the input directory.
3. The `bin` directory directly beneath each child, when present.

A location is included when it directly contains at least one `.COM`, `.EXE`,
or `.BAT` file. Scanning is deterministic and case-insensitive, with natural
numeric ordering (`APP2` before `APP10`):

1. The input directory has first precedence.
2. Child directories are processed in natural sort order.
3. A child's `bin` directory is processed before the child itself.
4. Files are processed by extension: `.COM`, `.EXE`, then `.BAT`.
5. Filenames within each extension group use natural sort order.
6. Each explicit filename key is registered before its extensionless alias.

## Limits

The utility uses fixed memory and DOS command-line limits:

- 63 characters per argument
- 96 characters per path
- 126 characters in the generated `APPEND` command
- 128 immediate child directories
- 256 files in any one extension group within a directory
- 1,024 unique command keys

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Success. |
| `1` | Invalid usage. |
| `2` | An argument is too long. |
| `3` | The generated `APPEND` command is too long. |
| `4` | The input path cannot be accessed or is not a directory. |
| `5` | The output path cannot be accessed or is not a directory. |
| `6` | Directory or file enumeration failed. |
| `7` | A compile-time capacity was exceeded. |
| `8` | Output or temporary-file I/O failed. |
| `9` | Writing to standard output failed. |

Errors are written to standard error. DOS failures include the hexadecimal DOS
error code.

## License

This project is licensed under the GNU General Public License v3.0. See
[`LICENSE`](LICENSE).
