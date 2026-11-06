complete -c ankh -f
complete -c ankh -n __fish_use_subcommand -a check -d 'Report on tools, gpg-agent, keys, the pass store and SSH'
complete -c ankh -n __fish_use_subcommand -a version -d 'Print the version'
complete -c ankh -n __fish_use_subcommand -a help -d 'Show the help'
complete -c ankh -n '__fish_seen_subcommand_from check' -l decrypt -d 'Also decrypt one entry; the value is discarded'
