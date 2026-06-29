# secret.jl — encrypt the deploy config at rest + gate every secret-touching op behind an INTERACTIVE
# REPL. The threat model: an LLM driving Archeion runs in non-interactive `julia -e`/`julia script.jl`
# processes (isinteractive()==false) — those MUST NOT be able to decrypt, view, set, or overwrite the
# config. Only a human at a TTY REPL (isinteractive()==true) can. The decrypted creds never touch disk:
# the password is read with `Base.getpass` (no echo) and handed to openssl via stdin (memory only); the
# plaintext config exists only in the agent's process memory (see agent.jl).

# Refuse unless we're in an interactive REPL on a real terminal. This is THE boundary that keeps the LLM
# (always non-interactive here) out of the secret. `julia -e`/`julia file.jl` → isinteractive()==false.
function _require_repl(op::AbstractString)
    if !isinteractive() || !(stdin isa Base.TTY)
        error(
            "Archeion: `$(op)` is REPL-only — it must be run interactively at a terminal (a human), " *
            "not from a script or an automated/LLM session. Open a Julia REPL on this host and retry.",
        )
    end
    return nothing
end

# openssl AES-256-CBC + PBKDF2. Password ONLY via stdin (an IOBuffer = memory); never on argv/env/disk.
const _ENC = `-aes-256-cbc -pbkdf2 -md sha256`

function _encrypt_file(
    plain_path::AbstractString, enc_path::AbstractString, password::AbstractString
)
    inp = IOBuffer()
    write(inp, password, "\n")
    seekstart(inp)
    run(
        pipeline(
            `openssl enc $_ENC -salt -pass stdin -in $plain_path -out $enc_path`; stdin=inp
        ),
    )
    return enc_path
end

# Decrypt → plaintext TOML STRING in memory (stdout captured). Wrong password → openssl errors (caught
# by the caller); the secret is never emitted on failure.
function _decrypt_to_string(enc_path::AbstractString, password::AbstractString)
    isfile(enc_path) || error("Archeion: encrypted config not found: $(enc_path)")
    inp = IOBuffer()
    write(inp, password, "\n")
    seekstart(inp)
    out = IOBuffer()
    run(pipeline(`openssl enc -d $_ENC -pass stdin -in $enc_path`; stdin=inp, stdout=out))
    return String(take!(out))
end

"""
    lock_config(plain_path; out="config.enc", shred=false) -> out

REPL-ONLY. Encrypt a plaintext config TOML (which carries the FTP creds + deploy target) into `out`,
prompting twice for a password (hidden). After this, the plaintext is no longer needed — pass
`shred=true` to delete it (overwrite then remove). The encrypted `out` is safe to keep in the tree;
without the password it reveals nothing, and the LLM (non-interactive) can never decrypt it.
"""
function lock_config(
    plain_path::AbstractString; out::AbstractString="config.enc", shred::Bool=false
)
    _require_repl("lock_config")
    isfile(plain_path) || error("lock_config: plaintext config not found: $(plain_path)")
    p1 = Base.getpass("New config password")
    p2 = Base.getpass("Confirm password")
    s1, s2 = read(p1, String), read(p2, String)
    Base.shred!(p1)
    Base.shred!(p2)
    s1 == s2 || (s1=s2 = ""; error("lock_config: passwords did not match."))
    isempty(s1) && error("lock_config: empty password refused.")
    _encrypt_file(plain_path, out, s1)
    s1 = s2 = ""
    if shred
        # best-effort overwrite then remove (the plaintext creds shouldn't linger)
        try
            sz = filesize(plain_path)
            open(plain_path, "w") do io
                return write(io, zeros(UInt8, sz))
            end
        catch
        end
        rm(plain_path; force=true)
    end
    @info "lock_config: wrote encrypted config" out shredded_plaintext = shred
    return out
end

"""
    view_config(enc_path="config.enc")

REPL-ONLY. Prompt for the password (hidden) and print the decrypted config to the terminal. This is the
ONLY way to read the config back, and it works solely in an interactive REPL — an automated/LLM session
(non-interactive) is refused, and there is no socket/agent op that reveals the config.
"""
function view_config(enc_path::AbstractString="config.enc")
    _require_repl("view_config")
    pw = Base.getpass("Config password")
    s = read(pw, String)
    Base.shred!(pw)
    plain = try
        _decrypt_to_string(enc_path, s)
    catch
        s = ""
        error("view_config: decryption failed (wrong password or corrupt file).")
    end
    s = ""
    print(plain)
    return nothing
end
