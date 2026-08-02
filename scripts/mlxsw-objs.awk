# Parse a kernel-style Makefile/Kbuild into flat object-list records.
#
# Emits one record per line:
#   MOD  <CONFIG_SYM|-> <rhs>   an obj-$(CONFIG_X) += foo.o  (or obj-m += foo.o)
#   BASE <module> <rhs>         a  foo-objs := a.o b.o
#   COND <module> <CONFIG_SYM> <rhs>   a foo-$(CONFIG_X) += c.o
#   UNKNOWN <line>              anything else that is not blank or a comment
#
# The caller resolves CONFIG symbols and assembles the final lists; this stage
# deliberately makes no policy decisions, so the same parser reads both the
# kernel's shipped Makefile and a Kbuild we generated from it.
#
# POSIX awk only -- no gensub(), no 3-arg match(). Debian's default awk is
# mawk, and this runs inside the build VM.

function trim(s) {
	sub(/^ /, "", s)
	sub(/ $/, "", s)
	return s
}

{
	line = $0
	# Join backslash continuations into one logical line.
	while (line ~ /\\[ \t]*$/) {
		sub(/\\[ \t]*$/, "", line)
		if ((getline nxt) <= 0)
			break
		line = line " " nxt
	}

	gsub(/[ \t]+/, " ", line)
	line = trim(line)
	if (line == "" || line ~ /^#/)
		next

	# Compiler/linker flag variables carry no objects. Skipping them
	# explicitly keeps UNKNOWN meaningful: an UNKNOWN line is then always
	# something that might have been an object list and was not understood,
	# which is worth a warning. Our own generated Kbuild opens with a
	# ccflags-y block, so without this the round-trip warns about itself.
	if (line ~ /^(subdir-)?(cc|c|as|ld)flags-[ym] ?[+:]?=/)
		next

	# obj-$(CONFIG_MLXSW_CORE) += mlxsw_core.o
	if (line ~ /^obj-\$\(CONFIG_[A-Z0-9_]+\) ?\+=/) {
		sym = line
		sub(/^obj-\$\(CONFIG_/, "", sym)
		sub(/\).*$/, "", sym)
		rhs = line
		sub(/^[^+:]*[+:]?= ?/, "", rhs)
		print "MOD " sym " " rhs
		next
	}

	# obj-m += mlxsw_core.o   (the form our generated Kbuild uses)
	if (line ~ /^obj-m ?\+=/) {
		rhs = line
		sub(/^[^+:]*[+:]?= ?/, "", rhs)
		print "MOD - " rhs
		next
	}

	# mlxsw_core-objs := core.o core_env.o ...
	if (line ~ /^[A-Za-z0-9_]+-objs ?:=/) {
		mod = line
		sub(/-objs.*$/, "", mod)
		rhs = line
		sub(/^[^+:]*[+:]?= ?/, "", rhs)
		print "BASE " mod " " rhs
		next
	}

	# mlxsw_core-$(CONFIG_MLXSW_CORE_HWMON) += core_hwmon.o
	if (line ~ /^[A-Za-z0-9_]+-\$\(CONFIG_[A-Z0-9_]+\) ?\+=/) {
		mod = line
		sub(/-\$\(CONFIG_.*$/, "", mod)
		sym = line
		sub(/^[A-Za-z0-9_]+-\$\(CONFIG_/, "", sym)
		sub(/\).*$/, "", sym)
		rhs = line
		sub(/^[^+:]*[+:]?= ?/, "", rhs)
		print "COND " mod " " sym " " rhs
		next
	}

	print "UNKNOWN " line
}
