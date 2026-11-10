# Convert OpenWrt's package/utils/busybox/Config-defaults.in into a BusyBox
# .config holding exactly the defaults a stock x86/64 image is built with.
# Conditional defaults are evaluated with IPV6=y and every other symbol
# (target selections such as TARGET_bcm53xx) treated as unset.
function flush() {
	if (name == "") return
	if (type == "bool") {
		if (value == "y") print "CONFIG_" name "=y"
		else print "# CONFIG_" name " is not set"
	} else if (type != "") {
		print "CONFIG_" name "=" value
	}
	name = ""; type = ""; value = ""; chosen = 0
}
/^config BUSYBOX_DEFAULT_/ {
	flush()
	name = substr($2, length("BUSYBOX_DEFAULT_") + 1)
	next
}
/^[ \t]+(bool|string|int|hex)[ \t]*$/ { type = $1; next }
/^[ \t]+default / {
	if (chosen) next
	line = $0
	sub(/^[ \t]+default /, "", line)
	cond = ""
	if (match(line, / if /)) {
		cond = substr(line, RSTART + 4)
		line = substr(line, 1, RSTART - 1)
	}
	if (cond == "" || cond == "IPV6") { value = line; chosen = 1 }
	next
}
END { flush() }
