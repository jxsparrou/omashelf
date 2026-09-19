#!/usr/bin/env python3

import asyncio
import json
import re

from dbus_next import Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method, signal


PLAYER_NAME = "org.mpris.MediaPlayer2.spokenshelf"
OBJECT_PATH = "/org/mpris/MediaPlayer2"


async def ipc(action, *args):
    process = await asyncio.create_subprocess_exec(
        "omarchy-shell",
        "spokenshelf",
        action,
        *(str(arg) for arg in args),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    output, _ = await process.communicate()
    return output.decode().strip() if process.returncode == 0 else ""


class MprisRoot(ServiceInterface):
    def __init__(self):
        super().__init__("org.mpris.MediaPlayer2")

    @method()
    def Raise(self):
        pass

    @method()
    def Quit(self):
        pass

    @dbus_property(access=PropertyAccess.READ)
    def CanQuit(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def CanRaise(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def HasTrackList(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Identity(self) -> "s":
        return "SpokenShelf"

    @dbus_property(access=PropertyAccess.READ)
    def DesktopEntry(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def SupportedUriSchemes(self) -> "as":
        return []

    @dbus_property(access=PropertyAccess.READ)
    def SupportedMimeTypes(self) -> "as":
        return ["audio/mpeg", "audio/mp4", "audio/aac", "audio/ogg", "audio/flac"]


class MprisPlayer(ServiceInterface):
    def __init__(self):
        super().__init__("org.mpris.MediaPlayer2.Player")
        self.state = {}
        self._volume = 1.0

    def run(self, action, *args):
        asyncio.create_task(ipc(action, *args))

    def track_id(self):
        item_id = re.sub(r"[^A-Za-z0-9_]", "_", self.state.get("itemId", "current"))
        return "/org/mpris/MediaPlayer2/Track/" + (item_id or "current")

    @method()
    def Next(self):
        self.run("skip", 30)

    @method()
    def Previous(self):
        self.run("skip", -30)

    @method()
    def Pause(self):
        self.run("pause")

    @method()
    def PlayPause(self):
        self.run("playPause")

    @method()
    def Stop(self):
        self.run("pause")

    @method()
    def Play(self):
        self.run("play")

    @method()
    def Seek(self, offset: "x"):
        self.run("skip", offset / 1_000_000)
        self.Seeked(max(0, self.Position + offset))

    @method()
    def SetPosition(self, track_id: "o", position: "x"):
        if track_id == self.track_id():
            self.run("seek", position / 1_000_000)
            self.Seeked(position)

    @method()
    def OpenUri(self, uri: "s"):
        pass

    @signal()
    def Seeked(self, position: "x") -> "x":
        return position

    @dbus_property(access=PropertyAccess.READ)
    def PlaybackStatus(self) -> "s":
        if not self.state.get("title"):
            return "Stopped"
        return "Playing" if self.state.get("playing") else "Paused"

    @dbus_property(access=PropertyAccess.READWRITE)
    def LoopStatus(self) -> "s":
        return "None"

    @LoopStatus.setter
    def LoopStatus(self, value: "s"):
        pass

    @dbus_property(access=PropertyAccess.READWRITE)
    def Rate(self) -> "d":
        return 1.0

    @Rate.setter
    def Rate(self, value: "d"):
        pass

    @dbus_property(access=PropertyAccess.READWRITE)
    def Shuffle(self) -> "b":
        return False

    @Shuffle.setter
    def Shuffle(self, value: "b"):
        pass

    @dbus_property(access=PropertyAccess.READ)
    def Metadata(self) -> "a{sv}":
        title = self.state.get("title", "")
        metadata = {
            "mpris:trackid": Variant("o", self.track_id()),
            "mpris:length": Variant("x", int(float(self.state.get("duration", 0)) * 1_000_000)),
            "xesam:title": Variant("s", title),
            "xesam:artist": Variant("as", [self.state.get("author", "")]),
        }
        cover = self.state.get("cover", "")
        if cover:
            metadata["mpris:artUrl"] = Variant("s", cover)
        return metadata

    @dbus_property(access=PropertyAccess.READWRITE)
    def Volume(self) -> "d":
        return self._volume

    @Volume.setter
    def Volume(self, value: "d"):
        self._volume = max(0.0, min(1.0, value))
        self.run("volume", self._volume)

    @dbus_property(access=PropertyAccess.READ)
    def Position(self) -> "x":
        return int(float(self.state.get("position", 0)) * 1_000_000)

    @dbus_property(access=PropertyAccess.READ)
    def MinimumRate(self) -> "d":
        return 1.0

    @dbus_property(access=PropertyAccess.READ)
    def MaximumRate(self) -> "d":
        return 1.0

    @dbus_property(access=PropertyAccess.READ)
    def CanGoNext(self) -> "b":
        return bool(self.state.get("title"))

    @dbus_property(access=PropertyAccess.READ)
    def CanGoPrevious(self) -> "b":
        return bool(self.state.get("title"))

    @dbus_property(access=PropertyAccess.READ)
    def CanPlay(self) -> "b":
        return bool(self.state.get("title"))

    @dbus_property(access=PropertyAccess.READ)
    def CanPause(self) -> "b":
        return bool(self.state.get("title"))

    @dbus_property(access=PropertyAccess.READ)
    def CanSeek(self) -> "b":
        return bool(self.state.get("title"))

    @dbus_property(access=PropertyAccess.READ)
    def CanControl(self) -> "b":
        return True

    async def refresh(self):
        raw = await ipc("status")
        if not raw:
            return
        try:
            state = json.loads(raw)
        except json.JSONDecodeError:
            return
        changed = (
            state.get("playing") != self.state.get("playing")
            or state.get("title") != self.state.get("title")
            or state.get("duration") != self.state.get("duration")
            or state.get("volume") != self.state.get("volume")
        )
        self.state = state
        self._volume = float(state.get("volume", self._volume))
        if changed:
            self.emit_properties_changed({
                "PlaybackStatus": self.PlaybackStatus,
                "Metadata": self.Metadata,
                "Volume": self.Volume,
                "CanPlay": self.CanPlay,
                "CanPause": self.CanPause,
                "CanSeek": self.CanSeek,
                "CanGoNext": self.CanGoNext,
                "CanGoPrevious": self.CanGoPrevious,
            })


async def main():
    bus = await MessageBus().connect()
    root = MprisRoot()
    player = MprisPlayer()
    bus.export(OBJECT_PATH, root)
    bus.export(OBJECT_PATH, player)
    await bus.request_name(PLAYER_NAME)
    while True:
        await player.refresh()
        await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())
