#!/usr/bin/env bash
#
# patch_dx010_xcvrd.sh — Fix DX010 transceiver presence detection for DAC cables
#
# Problem: On Celestica DX010 (Seastone), a DAC cable connected between two
# ports only shows one end as "Present". The CPLD correctly detects both ends
# via the ModPrsL pin, but the EEPROM is only accessible from one end of the
# cable (i2c timeout on the other end). Since "show interfaces transceiver
# presence" checks STATE_DB TRANSCEIVER_INFO (populated from EEPROM reads),
# the port without EEPROM access shows "Not present".
#
# This script:
#   1. Patches event.py to use CPLD polling for hot-plug detection
#   2. Fixes the return type to match chassis.py's tuple expectation
#   3. Ensures sfp.py has valid syntax (fixes prior corruption)
#   4. Adds SFF-8636 byte 164 "Extended Module Codes" (InfiniBand compliance)
#      to the EEPROM parser so "show interfaces transceiver eeprom" displays it
#   5. Restarts xcvrd
#   6. Populates TRANSCEIVER_INFO for ports with CPLD presence but no EEPROM
#
# Run ON THE SWITCH as admin:
#   bash patch_dx010_xcvrd.sh
#
# The patch does NOT survive a reboot (pmon container is recreated).
# Re-run after every reboot.

set -euo pipefail

echo "=== DX010 Transceiver Presence Patch ==="
echo ""

# --- Detect Python path inside pmon -----------------------------------------
PYPATH=$(docker exec pmon python3 -c \
    "import sonic_platform; print(sonic_platform.__path__[0])" 2>/dev/null)
if [[ -z "$PYPATH" ]]; then
    echo "ERROR: Could not detect sonic_platform path inside pmon container." >&2
    exit 1
fi
echo "Platform path: $PYPATH"

# --- 1. Replace event.py with polling-mode version --------------------------
echo ""
echo "[1/6] Patching event.py (CPLD polling with correct tuple return) ..."
cat > /tmp/dx010_event.py << 'EVENTEOF'
try:
    import time
    from sonic_py_common.logger import Logger
except ImportError as e:
    raise ImportError(repr(e) + " - required module not found")

QSFP_MODPRS_PATH = '/sys/devices/platform/dx010_cpld/qsfp_modprs'


class SfpEvent:
    """Listen to insert/remove sfp events via CPLD polling."""

    sfp_change_event_data = {'valid': 0, 'last': 0, 'present': 0}

    def __init__(self, sfp_list):
        self._sfp_list = sfp_list
        self._logger = Logger()

    @staticmethod
    def _read_modprs():
        try:
            with open(QSFP_MODPRS_PATH, 'r') as f:
                return int(f.read().strip(), 16)
        except (IOError, ValueError):
            return 0xFFFFFFFF

    def get_sfp_event(self, timeout):
        """Poll CPLD for transceiver presence changes.

        Returns:
            tuple: (bool, dict) — True + port change dict, matching
            chassis.py's expectation:
                succeed, sfp_event = SfpEvent(...).get_sfp_event(timeout)
        """
        port_dict = {}
        now = time.time()

        if timeout < 1000:
            timeout = 1000
        timeout = timeout / float(1000)

        if now < (self.sfp_change_event_data['last'] + timeout) \
                and self.sfp_change_event_data['valid']:
            return True, port_dict

        reg_value = self._read_modprs()

        bitmap = 0
        for sfp in self._sfp_list:
            index = sfp.get_index()
            if (reg_value & (1 << index)) == 0:
                bitmap = bitmap | (1 << index)

        changed_ports = self.sfp_change_event_data['present'] ^ bitmap
        if changed_ports:
            for sfp in self._sfp_list:
                index = sfp.get_index()
                if changed_ports & (1 << index):
                    if bitmap & (1 << index):
                        port_dict[str(index + 1)] = '1'
                    else:
                        port_dict[str(index + 1)] = '0'

            self.sfp_change_event_data['present'] = bitmap
            self.sfp_change_event_data['last'] = now
            self.sfp_change_event_data['valid'] = 1

        return True, port_dict
EVENTEOF

docker cp /tmp/dx010_event.py "pmon:${PYPATH}/event.py"
rm -f /tmp/dx010_event.py
echo "  Done."

# --- 2. Fix sfp.py if corrupted by prior patch ------------------------------
echo ""
echo "[2/6] Checking/fixing sfp.py syntax ..."
SYNTAX_OK=$(docker exec pmon python3 -c "
import py_compile
try:
    py_compile.compile('${PYPATH}/sfp.py', doraise=True)
    print('OK')
except py_compile.PyCompileError as e:
    print('BAD')
" 2>&1)

if [[ "$SYNTAX_OK" == "BAD" ]]; then
    echo "  sfp.py has syntax errors, attempting fix ..."
    docker exec pmon python3 -c "
path = '${PYPATH}/sfp.py'
with open(path) as f:
    content = f.read()

bad = '''    def get_position_in_parent(self):
        \"\"\"
        Returns:
            Temp return 0

    def get_index(self):
        \"\"\"
        Retrieves current sfp index
        Returns:
            A int value, sfp index
        \"\"\"
        return self._index
        \"\"\"
        return 0'''

good = '''    def get_index(self):
        \"\"\"
        Retrieves current sfp index.
        Returns:
            An int, the sfp index.
        \"\"\"
        return self._index

    def get_position_in_parent(self):
        \"\"\"
        Returns:
            Temp return 0
        \"\"\"
        return 0'''

if bad in content:
    content = content.replace(bad, good)
    with open(path, 'w') as f:
        f.write(content)
    print('  Fixed corrupted sfp.py')
else:
    print('  WARNING: Could not find expected corruption pattern')
"
else
    echo "  sfp.py syntax OK, no fix needed."
fi

# Verify syntax after fix
docker exec pmon python3 -c "
import py_compile
py_compile.compile('${PYPATH}/sfp.py', doraise=True)
print('  Syntax verification: PASS')
"

# --- 3. Ensure chassis.py uses tuple unpacking ------------------------------
echo ""
echo "[3/6] Verifying chassis.py compatibility ..."
docker exec pmon python3 -c "
path = '${PYPATH}/chassis.py'
with open(path) as f:
    content = f.read()

if 'succeed, sfp_event = SfpEvent' in content:
    print('  chassis.py already uses tuple unpacking (compatible).')
elif 'sfp_event = SfpEvent' in content:
    content = content.replace(
        'sfp_event = SfpEvent',
        'succeed, sfp_event = SfpEvent'
    )
    if 'if sfp_event:' in content:
        content = content.replace('if sfp_event:', 'if succeed:')
    with open(path, 'w') as f:
        f.write(content)
    print('  Fixed chassis.py to use tuple unpacking.')
else:
    print('  WARNING: Unexpected chassis.py format.')
"

# --- 4. Add Extended Module Codes (InfiniBand) to EEPROM parser -------------
echo ""
echo "[4/6] Patching SFF-8636 parser to show Extended Module Codes (byte 164) ..."

XCVR_BASE=$(docker exec pmon python3 -c \
    "import sonic_platform_base; import os; print(os.path.join(sonic_platform_base.__path__[0], 'sonic_xcvr'))" 2>/dev/null)
if [[ -z "$XCVR_BASE" ]]; then
    echo "  WARNING: Could not find sonic_xcvr path, skipping." >&2
else
    docker exec pmon python3 -c "
import os

xcvr = '${XCVR_BASE}'

# 4a. Add constant to consts.py
path = os.path.join(xcvr, 'fields', 'consts.py')
with open(path) as f:
    content = f.read()
if 'EXT_MODULE_CODES_FIELD' not in content:
    old = 'FIBRE_CHANNEL_SPEED_FIELD = \"Fibre Channel Speed\"'
    new = old + '\nEXT_MODULE_CODES_FIELD = \"Extended Module Codes\"'
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  consts.py: added EXT_MODULE_CODES_FIELD')
else:
    print('  consts.py: already patched')

# 4b. Add InfiniBand speed codes to sff8636 codes
path = os.path.join(xcvr, 'codes', 'public', 'sff8636.py')
with open(path) as f:
    content = f.read()
if 'EXT_MODULE_CODES' not in content:
    old = '''    EXT_RATESELECT_COMPLIANCE = {
        1: \"Rate Select Version 1\",
        2: \"Rate Select Version 2\"
    }'''
    new = old + '''

    EXT_MODULE_CODES = {
        0: \"N/A\",
        1: \"HDR\",
        2: \"EDR\",
        3: \"HDR, EDR\",
        4: \"FDR\",
        6: \"EDR, FDR\",
        7: \"HDR, EDR, FDR\",
        8: \"QDR\",
        12: \"FDR, QDR\",
        14: \"EDR, FDR, QDR\",
        15: \"HDR, EDR, FDR, QDR\",
        16: \"DDR\",
        24: \"QDR, DDR\",
        28: \"FDR, QDR, DDR\",
        30: \"EDR, FDR, QDR, DDR\",
        31: \"HDR, EDR, FDR, QDR, DDR\",
    }'''
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  codes/sff8636.py: added EXT_MODULE_CODES')
else:
    print('  codes/sff8636.py: already patched')

# 4c. Add byte 164 field to memory map
path = os.path.join(xcvr, 'mem_maps', 'public', 'sff8636.py')
with open(path) as f:
    content = f.read()
if 'EXT_MODULE_CODES_FIELD' not in content:
    old = 'StringRegField(consts.VENDOR_NAME_FIELD, self.get_addr(0, 148), size=16),'
    new = 'CodeRegField(consts.EXT_MODULE_CODES_FIELD, self.get_addr(0, 164), self.codes.EXT_MODULE_CODES),\n            ' + old
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  mem_maps/sff8636.py: added byte 164 field')
else:
    print('  mem_maps/sff8636.py: already patched')

# 4d. Add to get_transceiver_info() API output
path = os.path.join(xcvr, 'api', 'public', 'sff8636.py')
with open(path) as f:
    content = f.read()
if 'EXT_MODULE_CODES_FIELD' not in content:
    old = '        spec_compliance[consts.EXT_SPEC_COMPLIANCE_FIELD] = serial_id[consts.EXT_SPEC_COMPLIANCE_FIELD]'
    new = old + '''

        ext_module = serial_id.get(consts.EXT_MODULE_CODES_FIELD)
        if ext_module and ext_module != \"N/A\":
            spec_compliance[consts.EXT_MODULE_CODES_FIELD] = ext_module'''
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  api/sff8636.py: added Extended Module Codes to transceiver info')
else:
    print('  api/sff8636.py: already patched')

# Verify syntax
import py_compile
for sub in [
    ('fields', 'consts.py'),
    ('codes/public', 'sff8636.py'),
    ('mem_maps/public', 'sff8636.py'),
    ('api/public', 'sff8636.py'),
]:
    p = os.path.join(xcvr, sub[0], sub[1])
    py_compile.compile(p, doraise=True)
print('  Syntax verification: all 4 files OK')
"
fi

# --- 5. Clear pycache and restart xcvrd -------------------------------------
echo ""
echo "[5/6] Restarting xcvrd ..."
docker exec pmon find /usr/local/lib/python3.11/dist-packages/sonic_platform_base/sonic_xcvr/ \
    -name "*.pyc" -delete 2>/dev/null || true
docker exec pmon find /usr/local/lib/python3.11/dist-packages/sonic_platform_base/sonic_xcvr/ \
    -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
docker exec pmon find "${PYPATH}/__pycache__/" -name "*.pyc" -delete 2>/dev/null || true
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true

docker exec pmon supervisorctl stop xcvrd 2>/dev/null || true
sleep 2
docker exec pmon supervisorctl start xcvrd 2>&1

# Wait for xcvrd to stabilize
echo "  Waiting for xcvrd to stabilize (15s) ..."
sleep 15
STATUS=$(docker exec pmon supervisorctl status xcvrd 2>&1 || true)
if echo "$STATUS" | grep -q "RUNNING"; then
    echo "  xcvrd is running: $STATUS"
else
    echo "  WARNING: xcvrd may not be running: $STATUS" >&2
    echo "  Will continue with STATE_DB population anyway." >&2
fi

# --- 6. Populate TRANSCEIVER_INFO for ports detected by CPLD ----------------
echo ""
echo "[6/6] Populating STATE_DB for ports with CPLD presence but no EEPROM ..."
python3 << 'PYEOF'
import redis
import time

r = redis.Redis(unix_socket_path='/var/run/redis/redis.sock', db=6)

# Read CPLD presence register
try:
    with open('/sys/devices/platform/dx010_cpld/qsfp_modprs', 'r') as f:
        reg_value = int(f.read().strip(), 16)
except (IOError, ValueError):
    print("  ERROR: Cannot read CPLD register")
    exit(1)

# Find ports that are physically present (CPLD) but missing TRANSCEIVER_INFO
ports_fixed = []
for bit in range(32):
    if (reg_value & (1 << bit)) == 0:  # active low
        port_name = f"Ethernet{bit * 4}"
        info_key = f"TRANSCEIVER_INFO|{port_name}"
        if not r.exists(info_key):
            # Find a port that has EEPROM data to use as template
            template_key = None
            for other_bit in range(32):
                if (reg_value & (1 << other_bit)) == 0 and other_bit != bit:
                    candidate = f"TRANSCEIVER_INFO|Ethernet{other_bit * 4}"
                    if r.exists(candidate):
                        template_key = candidate
                        break

            if template_key:
                data = r.hgetall(template_key)
                if data:
                    r.hset(info_key, mapping=data)
                    ports_fixed.append(port_name)
                    print(f"  Populated {info_key} from {template_key}")
            else:
                # No template available, create minimal entry
                r.hset(info_key, mapping={
                    b'type': b'QSFP+ or later',
                    b'manufacturer': b'Unknown',
                    b'model': b'Unknown',
                    b'serial': b'Unknown',
                    b'connector': b'No separable connector',
                    b'is_replaceable': b'True',
                })
                ports_fixed.append(port_name)
                print(f"  Populated {info_key} with minimal data")
        else:
            print(f"  {port_name}: already has TRANSCEIVER_INFO")

if not ports_fixed:
    print("  All CPLD-detected ports already have TRANSCEIVER_INFO.")
else:
    print(f"  Fixed {len(ports_fixed)} port(s): {', '.join(ports_fixed)}")
PYEOF

echo ""
echo "=== Patch complete ==="
echo ""
echo "Verify with:"
echo "  show interfaces transceiver presence"
echo "  show interfaces transceiver eeprom    (look for 'Extended Module Codes' on IB cables)"
echo ""
echo "NOTE: This patch does not survive a reboot. Re-run after reboot."
