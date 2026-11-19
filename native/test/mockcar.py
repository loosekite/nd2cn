#!/usr/bin/env python3
"""A stand-in for the CMU vehicle services, for testing nd2cn-dashd.

Sends what was captured on the car (2026-11-17): 10 frames a second, each
CarSpeedResp, WheelSpeedNotification, the com.jci.vbs.vdt values that
changed, CylinderDeactivation; brake / gear / throttle only on change.
Answers the Get... methods the daemon calls.

usage: mockcar.py BUS_SOCKET [SECONDS] [SCENARIO]
scenarios: idle (standing, engine running), drive, noend (no end marker),
           lateend (vdt values after the end marker), silent (no frames)
"""
import math
import os
import struct
import sys
import time

import dbus
import dbus.lowlevel
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

sock = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 5
scenario = sys.argv[3] if len(sys.argv) > 3 else "idle"

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection("unix:path=" + sock)
state = {"brake": 1, "gear": 0, "lever": 1, "n": 0, "t0": time.time(), "last": {}}


class Bcm(dbus.service.Object):
    @dbus.service.method("com.jci.vbs.bcm", out_signature="y")
    def GetBrkPedalDepressedStatus(self):
        return dbus.Byte(state["brake"])

    @dbus.service.method("com.jci.vbs.bcm", out_signature="y")
    def GetGearPos(self):
        return dbus.Byte(state["gear"])

    @dbus.service.method("com.jci.vbs.bcm", out_signature="y")
    def GetTransmChangeLeverPosition(self):
        return dbus.Byte(state["lever"])


class Lds(dbus.service.Object):
    @dbus.service.method("com.jci.lds.data", out_signature="itddidddd")
    def GetPosition(self):
        t = time.time() - state["t0"]
        return (dbus.Int32(3), dbus.UInt64(1794878786 + int(t)), dbus.Double(31.2304567 + t * 1e-5),
                dbus.Double(121.4737891), dbus.Int32(8), dbus.Double(313.416),
                dbus.Double(36.5 if scenario == "drive" else 0.0), dbus.Double(0.9), dbus.Double(1.2))


names = [dbus.service.BusName(n, bus) for n in ("com.jci.vbs.bcm", "com.jci.lds.data")]
bcm = Bcm(bus, "/com/jci/vbs/bcm")
lds = Lds(bus, "/com/jci/lds/data")


def emit(iface, member, sig, *args):
    m = dbus.lowlevel.SignalMessage("/" + iface.replace(".", "/"), iface, member)
    m.append(*args, signature=sig)
    bus.send_message(m)


def changed(iface, member, value):
    """com.jci.vbs.vdt style: only when the value differs from the last one sent"""
    if state["last"].get(member) != value:
        state["last"][member] = value
        emit(iface, member, "q", dbus.UInt16(value))


# MOCK_SHM: the fake shared memory database. The driver's brake shows in
# BrakePressure as it does on the car (152 released, rising while pressed;
# one stray value while released, which must not count as a peak), the yaw
# rate moves while driving. Written in place: the daemon has it mapped.
shm = os.environ.get("MOCK_SHM", "")
shm_off = {}
if shm:
    with open(shm, "rb") as f:
        img = f.read()
    total, count = struct.unpack_from("<2I", img, 0)
    for i in range(count):
        name_off, size, typ, data_off = struct.unpack_from("<4I", img, 16 * (i + 1))
        shm_off[img[name_off:img.index(b"\0", name_off)].decode()] = data_off


def poke(name, v):
    if name in shm_off:
        with open(shm, "r+b") as f:
            f.seek(shm_off[name])
            f.write(struct.pack("<I", v))


def frame():
    n = state["n"]
    state["n"] += 1
    t = n / 10.0
    if time.time() - state["t0"] > seconds:
        loop.quit()
        return False
    if scenario == "silent":
        return True
    drive = scenario == "drive"
    spd = 10000 + (int(3650 + 400 * math.sin(t)) if drive else 0)
    emit("com.jci.vbs.bcm", "CarSpeedResp", "u", dbus.UInt32(spd))
    emit("com.jci.vbs.bcm", "WheelSpeedNotification", "(qqqqqqt)",
         (dbus.UInt16(621 + n), dbus.UInt16(0), dbus.UInt16(spd), dbus.UInt16(spd + 3),
          dbus.UInt16(spd - 2), dbus.UInt16(spd + 1), dbus.UInt64(0)))
    vdt = [("VehLong_A_Actl", 4009 + (n % 3) + (int(300 * math.sin(t)) if drive else 0)),
           ("EngAout_N_Actl", 400 + (n % 5) + (1500 if drive else 0)),
           ("Lateral_Acceleration", 3983 + (n % 7) + (int(500 * math.cos(t)) if drive else 0))]
    if drive:
        vdt += [("ApedPos_Pc_ActlArb", 350 + int(200 * math.sin(t))), ("Veh_V_ActlEng", spd - 10000 + 12),
                ("SteWhlComp_An_Est", 16000 + int(450 * math.sin(t / 2)))]
    late = scenario == "lateend" and n % 2 == 0
    if not late:
        for name, v in vdt:
            changed("com.jci.vbs.vdt", name, v)
    if scenario != "noend":
        emit("com.jci.vbs.eem", "CylinderDeactivation", "(yyy)", (dbus.Byte(0), dbus.Byte(3), dbus.Byte(0)))
    if late:
        for name, v in vdt:
            changed("com.jci.vbs.vdt", name, v)
    if shm:
        k = n % 30
        p = 3000 if k == 12 else (152 + 60 * (k - 14) if 15 <= k < 25 else 152)
        poke("BrakePressure", p)
        poke("YawRate", 2046 + (int(40 * math.sin(t)) if drive else n % 3 - 1))
    # the driver: brakes for 1 s every 3 s (from 1.5 s on), a gear at 2 s
    if n % 30 in (15, 25):
        state["brake"] = 2 if n % 30 == 15 else 1
        emit("com.jci.vbs.bcm", "BrakePedalDepressedStatus", "y", dbus.Byte(state["brake"]))
    if n == 20 and drive:
        state["gear"] = 3
        emit("com.jci.vbs.bcm", "GearPosNotification", "y", dbus.Byte(3))
    if n == 5:
        emit("com.jci.vbs.vwm", "OilPressureWarning_2", "b", dbus.Boolean(False))
        emit("com.jci.vbs.vwm", "BatteryChargingTelltale2", "b", dbus.Boolean(False))
    return True


loop = GLib.MainLoop()
GLib.timeout_add(100, frame)
loop.run()
