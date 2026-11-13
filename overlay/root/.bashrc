# Shell de l'opérateur. Volontairement minimal.

# L'historique est pré-rempli par l'image (voir .bash_history) : la commande
# d'effacement est accessible d'une flèche vers le haut. Ces réglages évitent
# qu'elle soit perdue ou dédupliquée au premier lancement.
HISTFILE="$HOME/.bash_history"
HISTSIZE=1000
HISTFILESIZE=1000
shopt -s histappend

# Invite courte et sans ambiguïté : on est root sur une image live.
PS1='\[\e[1;31m\]killbit\[\e[0m\]:\w# '

alias ll='ls -l'

# Rappel de l'aide si l'opérateur a perdu l'écran d'accueil.
aide() { /usr/local/sbin/killbit-session.sh --aide-seule; }
