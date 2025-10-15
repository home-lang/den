import type { BuiltinCommand } from '../types'
import { aliasCommand } from './alias'
import { bCommand } from './b'
import { bbCommand } from './bb'
import { bdCommand } from './bd'
import { bfCommand } from './bf'
import { bgCommand } from './bg'
import { biCommand } from './bi'
import { blCommand } from './bl'
import { bookmarkCommand } from './bookmark'
import { brCommand } from './br'
import { builtinCommand } from './builtin'
import { cdCommand } from './cd'
import { clearCommand } from './clear'
import { codeCommand } from './code'
import { commandCommand } from './command'
import { copysshCommand } from './copyssh'
import { dirsCommand } from './dirs'
import { disownCommand } from './disown'
import { dotfilesCommand } from './dotfiles'
import { echoCommand } from './echo'
import { emptytrashCommand } from './emptytrash'
import { envCommand } from './env'
import { evalCommand } from './eval'
import { execCommand } from './exec'
import { exitCommand } from './exit'
import { exportCommand } from './export'
import { falseCommand } from './false'
import { fgCommand } from './fg'
import { ftCommand } from './ft'
import { getoptsCommand } from './getopts'
import { hashCommand } from './hash'
import { helpCommand } from './help'
import { hideCommand } from './hide'
import { historyCommand } from './history'
import { ipCommand } from './ip'
import { jobsCommand } from './jobs'
import { killCommand } from './kill'
import { libraryCommand } from './library'
import { localipCommand } from './localip'
import { popdCommand } from './popd'
import { printfCommand } from './printf'
import { pstormCommand } from './pstorm'
import { pushdCommand } from './pushd'
import { pwdCommand } from './pwd'
import { readCommand } from './read'
import { reloadCommand } from './reload'
import { reloaddnsCommand } from './reloaddns'
import { createScriptBuiltins } from './script-builtins'
import { setCommand } from './set'
import { showCommand } from './show'
import { shrugCommand } from './shrug'
import { sourceCommand } from './source'
import { testCommand } from './test'
import { timeCommand } from './time'
import { timeoutCommand } from './timeout'
import { timesCommand } from './times'
import { trapCommand } from './trap'
import { trueCommand } from './true'
import { typeCommand } from './type'
import { umaskCommand } from './umask'
import { unaliasCommand } from './unalias'
import { unsetCommand } from './unset'
import { waitCommand } from './wait'
import { webCommand } from './web'
import { whichCommand } from './which'
import { wipCommand } from './wip'
import { yes } from './yes'

export function createBuiltins(): Map<string, BuiltinCommand> {
  const builtins = new Map<string, BuiltinCommand>()

  // Add all builtin commands in alphabetical order
  builtins.set('alias', aliasCommand)
  builtins.set('b', bCommand)
  builtins.set('bb', bbCommand)
  builtins.set('bd', bdCommand)
  builtins.set('bf', bfCommand)
  builtins.set('bg', bgCommand)
  builtins.set('bi', biCommand)
  builtins.set('bl', blCommand)
  builtins.set('bookmark', bookmarkCommand)
  builtins.set('bm', { ...bookmarkCommand, name: 'bm' })
  builtins.set('br', brCommand)
  builtins.set('mark', { ...bookmarkCommand, name: 'mark' })
  builtins.set('jump', { ...bookmarkCommand, name: 'jump' })
  builtins.set('builtin', builtinCommand)
  builtins.set('c', clearCommand)
  builtins.set('cd', cdCommand)
  builtins.set('command', commandCommand)
  builtins.set('code', codeCommand)
  builtins.set('copyssh', copysshCommand)
  builtins.set('dirs', dirsCommand)
  builtins.set('disown', disownCommand)
  builtins.set('dotfiles', dotfilesCommand)
  builtins.set('echo', echoCommand)
  builtins.set('emptytrash', emptytrashCommand)
  builtins.set('eval', evalCommand)
  builtins.set('env', envCommand)
  builtins.set('exec', execCommand)
  builtins.set('exit', exitCommand)
  builtins.set('export', exportCommand)
  builtins.set('false', falseCommand)
  builtins.set('fg', fgCommand)
  builtins.set('ft', ftCommand)
  builtins.set('getopts', getoptsCommand)
  builtins.set('hash', hashCommand)
  builtins.set('help', helpCommand)
  builtins.set('hide', hideCommand)
  builtins.set('history', historyCommand)
  builtins.set('ip', ipCommand)
  builtins.set('jobs', jobsCommand)
  builtins.set('kill', killCommand)
  builtins.set('library', libraryCommand)
  builtins.set('localip', localipCommand)
  builtins.set('pstorm', pstormCommand)
  builtins.set('popd', popdCommand)
  builtins.set('printf', printfCommand)
  builtins.set('pushd', pushdCommand)
  builtins.set('pwd', pwdCommand)
  builtins.set('read', readCommand)
  builtins.set('reload', reloadCommand)
  builtins.set('reloaddns', reloaddnsCommand)
  builtins.set('reloadshell', reloadCommand)
  builtins.set('set', setCommand)
  builtins.set('show', showCommand)
  builtins.set('shrug', shrugCommand)
  builtins.set('source', sourceCommand)
  builtins.set('.', { ...sourceCommand, name: '.' }) // POSIX alias for source
  builtins.set('test', testCommand)
  builtins.set('[', { ...testCommand, name: '[' }) // POSIX alias for test
  builtins.set('time', timeCommand)
  builtins.set('timeout', timeoutCommand)
  builtins.set('times', timesCommand)
  builtins.set('trap', trapCommand)
  builtins.set('true', trueCommand)
  builtins.set('type', typeCommand)
  builtins.set('umask', umaskCommand)
  builtins.set('unalias', unaliasCommand)
  builtins.set('unset', unsetCommand)
  builtins.set('wait', waitCommand)
  builtins.set('web', webCommand)
  builtins.set('which', whichCommand)
  builtins.set('wip', wipCommand)
  builtins.set('yes', { name: 'yes', execute: yes, description: 'Execute the last suggested script correction', usage: 'yes' })

  // Add script-related builtins
  const scriptBuiltins = createScriptBuiltins()
  for (const [name, builtin] of scriptBuiltins) {
    builtins.set(name, builtin)
  }

  return builtins
}
