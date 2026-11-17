import Foundation

/// The zsh hook printed by `keydillo shell-init`. Before each command it checks whether the command runs inside a
/// keydillo project (a folder whose .env has the `# --- keydillo ---` header), or names a path inside one. Only then
/// does it point that one command at a keydillo proxy; the settings are removed again before the next prompt.
/// Everything else you run in the terminal is left alone.
enum ShellHook {
  static let binDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("keydillo/bin").path

  static func zsh(cli: String) -> String {
    let vars = Runner.routedVars.joined(separator: " ")
    return """
    # keydillo shell hook (keydillo shell-init). Turn it off in keydillo Settings.
    [[ -n ${_kd_loaded-} ]] && return 0
    _kd_loaded=1
    path=(\(quote(binDir)) ${path:#\(quote(binDir))})
    _kd_cli=\(quote(cli))
    _kd_vars=(\(vars))
    typeset -ga _kd_saved
    typeset -gi _kd_on=0

    # True when $1 or a folder above it holds a .env with keydillo's header.
    _kd_in_project() {
      local d=$1
      while [[ -n $d && $d != / ]]; do
        [[ -r $d/.env && "$(<$d/.env)" == *"# --- keydillo ---"* ]] && return 0
        d=${d:h}
      done
      return 1
    }

    _kd_preexec() {
      [[ -n ${KEYDILLO_RUN-} ]] && return
      local hit=0 w p
      _kd_in_project $PWD && hit=1
      if (( ! hit )); then
        for w in ${(z)2}; do
          w=${(Q)w}
          [[ $w == */* ]] || continue
          p=${w/#\\~/$HOME}
          [[ -e $p ]] || continue
          [[ -d $p ]] || p=${p:h}
          _kd_in_project ${p:A} && { hit=1; break }
        done
      fi
      (( hit )) || return
      local out v
      out=$("$_kd_cli" run --shell-env $$) || return
      _kd_saved=()
      for v in $_kd_vars; do (( ${+parameters[$v]} )) && _kd_saved+=("$v=${(P)v}"); done
      eval "$out"
      _kd_on=1
    }

    _kd_precmd() {
      (( _kd_on )) || return
      unset $_kd_vars
      (( ${#_kd_saved} )) && export "${_kd_saved[@]}"
      _kd_saved=()
      _kd_on=0
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _kd_preexec
    add-zsh-hook precmd _kd_precmd
    """
  }

  static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
