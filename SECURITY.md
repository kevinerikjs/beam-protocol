# Security

Phoros defines message formats. It does not open connections, store secrets or encrypt anything. Applications that use it must:

- authenticate a peer before they accept control messages or media from it
- limit frame and payload sizes before they allocate (`FrameDecoder` does this)
- use TLS or an equivalent when a connection leaves the local network

## Reporting

Do not open a public issue for a security problem. Email [support@beamscreen.app](mailto:support@beamscreen.app) with the package version, a reproduction and the impact you expect. You will get a reply within seven days.
