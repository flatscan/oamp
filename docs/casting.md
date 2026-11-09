# Casting

OAmp can play to Chromecast speakers and displays (including Google Nest
speakers, displays and speaker groups) and to DLNA TVs and players. Tap the
cast button at the top left of Now playing and pick a device. While casting:

- The speaker or TV fetches each track from your server itself. Your phone
  or PC only sends commands, so the screen can lock.
- The volume slider on Windows and the volume buttons on Android change the
  device's own volume.
- ReplayGain and crossfade are off, because the device plays the tracks.
- Picking **This device**, or the device ending the session (for example
  when something else is cast to it), brings playback back to OAmp, paused
  at the same spot.

OAmp asks the device for the original file first. If the device can't play
it, OAmp asks again for a 320 kbps MP3 transcoded by the server.

## What the network needs

- **Discovery:** Cast devices are found with mDNS and DLNA devices with
  SSDP. Neither crosses between subnets or VLANs on its own. If your
  speakers are on a separate VLAN, you need an mDNS reflector and an SSDP
  relay (or multicast routing) between that VLAN and the one OAmp runs on.
- **Control:** OAmp connects to Cast devices on TCP 8009, and to DLNA
  devices on the port they advertise (often 9197 on Samsung TVs).
- **Streaming:** the device must be able to reach your server at the same
  address OAmp uses, and resolve its name the same way.

## Troubleshooting

**A Google speaker connects, then stops and goes back to the start, while
other devices work.** The speaker probably can't resolve or reach your
server. Google speakers often ignore the DNS server your router hands out
and ask Google's public DNS directly, sometimes over encrypted DNS (DNS over
TLS on port 853). If your server's name only exists on your own DNS, or
resolves to something else in public DNS (for example through a wildcard
record), the speaker gets the wrong answer. Fix it on your network: send
all DNS from the speakers to your own DNS servers (a NAT redirect of port
53), and block outbound port 853 and DNS over HTTPS to public resolvers so
nothing gets round it.

**A Google speaker can't play anything from the internet either.** Check
whether the speakers' network or VLAN blocks internet access.

**A TV plays but won't seek or pause.** Some DLNA renderers refuse commands
while they are still starting a track. OAmp waits and retries; if it still
fails, the error is in the diagnostics log (Settings → About).
