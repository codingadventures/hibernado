# hibernado - Development Commands

default:
    just --list

build:
    .vscode/build.sh

test:
    .vscode/build.sh && scp out/Hibernado.zip deck@192.168.1.18:~ && clear && ssh deck@192.168.1.18 'journalctl --follow'

clean:
    rm -rf out
    rm -rf dist
    rm -rf node_modules
    rm -rf .rollup.cache

watch:
    ssh deck@192.168.1.18 'journalctl --follow'

ssh:
    ssh deck@192.168.1.18

send:
    scp out/Hibernado.zip deck@192.168.1.18:~ && clear && ssh deck@192.168.1.18 'journalctl --follow'