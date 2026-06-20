import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print shell completion script.",
        discussion: """
        Add to your shell rc file:

          zsh:   source <(lingcode completion zsh)
          bash:  source <(lingcode completion bash)
          fish:  lingcode completion fish | source
        """
    )

    @Argument(help: "Shell: zsh, bash, or fish.")
    var shell: String

    func run() throws {
        switch shell.lowercased() {
        case "zsh":  print(zshCompletion)
        case "bash": print(bashCompletion)
        case "fish": print(fishCompletion)
        default:
            FileHandle.standardError.write(Data("lingcode: unknown shell '\(shell)'. Use zsh, bash, or fish.\n".utf8))
            throw ExitCode(2)
        }
    }
}

// MARK: - Zsh

private let zshCompletion = """
#compdef lingcode

_lingcode() {
  local context state state_descr line
  typeset -A opt_args

  _arguments -C \\
    '--version[Show version]' \\
    '--help[Show help]' \\
    '(-): :->command' \\
    '(-)*:: :->args'

  case $state in
    command)
      local commands=(
        'repl:Start an interactive multi-turn session'
        'ask:Send a one-shot prompt'
        'config:Get or set configuration'
        'init:Generate a CLAUDE.md for this project'
        'history:List past sessions'
        'completion:Print shell completion script'
        'ping:Check if LingCode.app is running'
        'open:Open a file or folder in LingCode.app'
        'status:Show current project and session'
        'watch:Stream agent events from the running app'
        'install:Install or uninstall the lingcode binary'
      )
      _describe 'command' commands
      ;;
    args)
      case $words[1] in
        ask|repl)
          _arguments \\
            '--provider[Provider: deepseek or claude]:provider:(deepseek claude)' \\
            '--permission-mode[Permission mode]:mode:(default acceptEdits plan dontAsk bypassPermissions)' \\
            '--yolo[Auto-allow all tool calls]' \\
            '--model[DeepSeek model]:model:(deepseek-v4-pro deepseek-v4-flash deepseek-chat deepseek-reasoner)' \\
            '--claude-model[Claude model override]:model:' \\
            '--headless[Force headless mode]' \\
            '--continue[Continue most recent session]' \\
            '--resume[Resume session by ID]:session_id:' \\
            '--no-claude-md[Skip loading CLAUDE.md]' \\
            '--file[Attach file to prompt]:file:_files' \\
            '--max-turns[Max agent turns]:n:' \\
            '--json[Output as JSON]' \\
            '--output[Write response to file]:file:_files' \\
            '1:prompt:'
          ;;
        config)
          local subcmds=('get' 'set' 'unset' 'list')
          _describe 'subcommand' subcmds
          ;;
        completion)
          local shells=('zsh' 'bash' 'fish')
          _describe 'shell' shells
          ;;
        history)
          _arguments \\
            '--all[All directories]' \\
            '--limit[Max entries]:n:' \\
            '--json[JSON output]' \\
            '--clear[Clear history]'
          ;;
        init)
          _arguments \\
            '--project[Project path]:dir:_files -/' \\
            '--force[Overwrite without prompting]' \\
            '--print[Preview without writing]'
          ;;
        open)
          _arguments '1:file:_files'
          ;;
      esac
      ;;
  esac
}

_lingcode "$@"
"""

// MARK: - Bash

private let bashCompletion = """
_lingcode_completions() {
  local cur prev words
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="repl ask config init history completion ping open status watch install"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    return 0
  fi

  local cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    ask|repl)
      local opts="--provider --permission-mode --yolo --model --claude-model --headless --continue --resume --no-claude-md --file --max-turns --json --output"
      COMPREPLY=($(compgen -W "$opts" -- "$cur"))
      ;;
    config)
      COMPREPLY=($(compgen -W "get set unset list" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "zsh bash fish" -- "$cur"))
      ;;
    history)
      COMPREPLY=($(compgen -W "--all --limit --json --clear --project" -- "$cur"))
      ;;
    init)
      COMPREPLY=($(compgen -W "--project --force --print" -- "$cur"))
      ;;
  esac
}

complete -F _lingcode_completions lingcode
"""

// MARK: - Fish

private let fishCompletion = """
# lingcode fish completions
set -l commands repl ask config init history completion ping open status watch install

complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a repl        -d 'Interactive session'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a ask         -d 'One-shot prompt'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a config      -d 'Get/set config'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a init        -d 'Generate CLAUDE.md'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a history     -d 'List sessions'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a completion  -d 'Shell completions'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a ping        -d 'Ping LingCode.app'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a open        -d 'Open in app'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a status      -d 'Show status'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a watch       -d 'Watch events'
complete -c lingcode -f -n "not __fish_seen_subcommand_from $commands" -a install     -d 'Install binary'

for sub in ask repl
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l provider        -d 'Provider' -a 'claude deepseek'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l permission-mode -d 'Mode'     -a 'default acceptEdits plan dontAsk bypassPermissions'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l yolo            -d 'Auto-allow all'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l continue        -d 'Resume last session'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l file            -d 'Attach file' -r -F
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l max-turns       -d 'Max turns'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l json            -d 'JSON output'
  complete -c lingcode -n "__fish_seen_subcommand_from $sub" -l output          -d 'Write to file' -r -F
end

complete -c lingcode -n "__fish_seen_subcommand_from config" -f -a "get set unset list"
complete -c lingcode -n "__fish_seen_subcommand_from completion" -f -a "zsh bash fish"
"""
