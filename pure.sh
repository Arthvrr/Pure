#!/bin/bash

# --- CONFIGURATION ---
# Couleurs pour le terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Chemins
TRASH_DIR="$HOME/.Trash"
DOWNLOADS_DIR="$HOME/Downloads"
DESKTOP_DIR="$HOME/Desktop"
CACHES_DIR="$HOME/Library/Caches"
LOGS_DIR="$HOME/Library/Logs"
XCODE_DIR="$HOME/Library/Developer/Xcode/DerivedData"

# --- FONCTIONS ---

function get_size() {
    # Récupère la taille d'un dossier (ex: 2.5G)
    if [ -d "$1" ]; then
        du -sh "$1" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

function count_files() {
    # Compte les fichiers (non récursif pour éviter les lenteurs)
    ls -1 "$1" 2>/dev/null | wc -l | xargs
}

function move_to_trash() {
    # Déplace vers la corbeille au lieu de supprimer (Sécurité)
    if [ -e "$1" ]; then
        mv "$1" "$TRASH_DIR/" 2>/dev/null
    fi
}

function print_header() {
    clear
    echo -e "${BLUE}${BOLD}✨ PURE.sh - Nettoyeur Mac${NC}"
    echo "--------------------------------"
}

# --- ANALYSE ---

print_header
echo -e "${BOLD}🔍 Analyse en cours...${NC}\n"

SIZE_CACHES=$(get_size "$CACHES_DIR")
SIZE_LOGS=$(get_size "$LOGS_DIR")
SIZE_XCODE=$(get_size "$XCODE_DIR")

# Pour Downloads et Desktop, on estime la taille globale pour l'affichage simple
SIZE_DL=$(get_size "$DOWNLOADS_DIR")
SIZE_DT=$(get_size "$DESKTOP_DIR")

echo -e "1. [Caches]      Système & Apps   : ${RED}$SIZE_CACHES${NC}"
echo -e "2. [Logs]        Journaux         : ${RED}$SIZE_LOGS${NC}"
echo -e "3. [Xcode]       DerivedData      : ${RED}$SIZE_XCODE${NC}"
echo -e "4. [Downloads]   (.dmg .pkg .zip) : (Dans $SIZE_DL total)"
echo -e "5. [Desktop]     (Screenshots)    : (Dans $SIZE_DT total)"
echo -e "6. [Corbeille]   Vider maintenant"
echo "--------------------------------"
echo -e "A. ${GREEN}Tout nettoyer (sauf corbeille)${NC}"
echo -e "Q. Quitter"
echo ""

# --- INTERACTION ---

read -p "Que veux-tu nettoyer ? (Entrer un numéro ou A) : " choice

case $choice in
    1)
        echo -e "\n🧹 Nettoyage des Caches..."
        # On déplace le CONTENU, pas le dossier lui-même
        for f in "$CACHES_DIR"/*; do move_to_trash "$f"; done
        echo "✅ Terminé."
        ;;
    2)
        echo -e "\n🧹 Nettoyage des Logs..."
        for f in "$LOGS_DIR"/*; do move_to_trash "$f"; done
        echo "✅ Terminé."
        ;;
    3)
        echo -e "\n🧹 Nettoyage Xcode DerivedData..."
        for f in "$XCODE_DIR"/*; do move_to_trash "$f"; done
        echo "✅ Terminé."
        ;;
    4)
        echo -e "\n🧹 Nettoyage des Installateurs (Downloads)..."
        # Find pour .dmg, .pkg, .zip (insensible à la casse)
        find "$DOWNLOADS_DIR" -maxdepth 1 \( -iname "*.dmg" -o -iname "*.pkg" -o -iname "*.zip" \) -exec mv {} "$TRASH_DIR/" \;
        echo "✅ Terminé."
        ;;
    5)
        echo -e "\n🧹 Nettoyage des Screenshots (Bureau)..."
        # Find pour les captures d'écran
        find "$DESKTOP_DIR" -maxdepth 1 \( -name "Capture d’écran*" -o -name "Screenshot*" \) -exec mv {} "$TRASH_DIR/" \;
        echo "✅ Terminé."
        ;;
    6)
        echo -e "\n🗑 Vidage de la corbeille..."
        # Utilisation d'AppleScript pour le son et l'UI Finder (comme ton script original)
        osascript -e 'tell application "Finder" to empty trash'
        afplay /System/Library/Sounds/Glass.aiff
        echo "✅ Corbeille vidée."
        ;;
    A|a)
        echo -e "\n🚀 Nettoyage Global..."
        
        echo "• Caches..."
        for f in "$CACHES_DIR"/*; do move_to_trash "$f"; done
        
        echo "• Logs..."
        for f in "$LOGS_DIR"/*; do move_to_trash "$f"; done
        
        echo "• Xcode..."
        for f in "$XCODE_DIR"/*; do move_to_trash "$f"; done
        
        echo "• Installateurs..."
        find "$DOWNLOADS_DIR" -maxdepth 1 \( -iname "*.dmg" -o -iname "*.pkg" -o -iname "*.zip" \) -exec mv {} "$TRASH_DIR/" \;
        
        echo "• Screenshots..."
        find "$DESKTOP_DIR" -maxdepth 1 \( -name "Capture d’écran*" -o -name "Screenshot*" \) -exec mv {} "$TRASH_DIR/" \;
        
        echo -e "${GREEN}✅ Tout a été déplacé dans la corbeille.${NC}"
        ;;
    Q|q)
        echo "Au revoir !"
        exit 0
        ;;
    *)
        echo "Choix invalide."
        ;;
esac

echo ""