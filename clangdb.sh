#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

export LC_ALL=C

compile_db="compile_commands.json"
clangd_inc=".clangd.inc"
clangd_dex=".clangd.dex"
clangd_cfg=".clangd"

get_include_dirs()
{
	local dirs gcc
	gcc=${1:-"gcc"}
	[ -x "$(which $gcc)" ] || return
	dirs=$($gcc -v -E -xc++ - </dev/null 2>&1)
	dirs=${dirs#*"#include <...> search starts here:"}
	dirs=${dirs%"End of search list."*}
	echo $(realpath $dirs 2>/dev/null)
}

copy_include_dirs()
{
	local i hash dest
	[ $# -lt 1 ] && return
	dest=${1:-$clangd_inc}
	shift 1
	[ -d "$dest" ] || mkdir -p $dest
	[ $? -ne 0 ] && return
	for i in $@; do
		hash=$(echo $i | md5sum)
		hash=${hash%%" "*}
		[ -d "$dest/$hash" ] && continue
		[ -d "$i" ] || continue
		cp -vrL $i $dest/$hash
	done
}

append_include_dirs()
{
	local i c cs cc db tmp dirs arg cmd
	db=${1:-$compile_db}

	cs=$(jq '.[] |
		if has("arguments") then
			.arguments[0]
		elif has("command") then
			.command | split(" ") | first
		else null end' $db | sed 's/null//g' | sort -u)

	for c in $cs; do
		cc=${c#\"}
		cc=${cc%\"}

		dirs=$(get_include_dirs $cc)
		[ -z "$dirs" ] && continue
		copy_include_dirs $clangd_inc $dirs

		unset arg cmd
		for i in $dirs; do
			i=$(echo $i | md5sum)
			i=-isystem$PWD/$clangd_inc/${i%%" "*}
			arg=$arg,\"$i\"
			cmd="$cmd $i"
		done
		arg="[${arg#,}]"

		tmp=$(mktemp)
		jq "map(
			if has(\"arguments\") and .arguments[0] == $c then
				.arguments += $arg
			elif has(\"command\") then
				if .command | startswith($c) then
					.command += \"$cmd\"
				else . end
			else . end)" $db > $tmp
		if [ $? -eq 0 ]; then
			cat $tmp > $db
		fi
		rm $tmp
	done
}

remove_duplicate_entry()
{
	local db tmp
	db=${1:-$compile_db}
	tmp=$(mktemp)
	jq 'unique_by(.directory + "/" + .file)' $db > $tmp
	if [ $? -eq 0 ]; then
		# mv break link, use cat instead
		cat $tmp > $db
	fi
	rm $tmp
}

act=$1
shift 1

case $act in
gen)
	if [ -f "$compile_db" ]; then
		cp $compile_db $compile_db.bak
		echo > $compile_db
	fi

	if [ $# -ne 0 ]; then
		bear $@
	elif [ -f CMakeLists.txt ]; then
		cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=1
	elif [ -f Makefile ]; then 
		bear make
	else
		return
	fi

	remove_duplicate_entry $compile_db
	append_include_dirs $compile_db

	if [ -s "$compile_db.bak" ]; then
		tmp=$(mktemp)
		jq -s '.[0] + .[1]' $compile_db $compile_db.bak > $tmp
		cat $tmp > $compile_db
		rm $tmp $compile_db.bak
		remove_duplicate_entry $compile_db
	fi
;;
mod)
	remove_duplicate_entry $compile_db
	append_include_dirs $compile_db
;;
dex)
	[ -f $clangd_cfg ] || cat << EOF > $clangd_cfg
CompileFlags:
  Add:
    - -ferror-limit=0
---
Index:
  External:
    File: $clangd_dex
EOF
	clangd-indexer --executor=all-TUs $compile_db  > $clangd_dex
;;
find)
	path=$(realpath $1)
	[ -z "$path" ] && return

	jq ".[] |
		if .file | startswith(\"/\") then
			select(.file == \"$path\") | .
		else
			select(.directory + \"/\" + .file == \"$path\") | .
		end" $compile_db
;;
esac
