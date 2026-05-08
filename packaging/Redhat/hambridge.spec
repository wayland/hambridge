# HaMBridge (hambridge) — RPM spec for Fedora / RHEL family (evdev → MQTT).
#
# Build a source tarball (top-level must include Makefile, src/, packaging/, …):
#   git archive --format=tar.gz --prefix=hambridge-%{version}/ -o hambridge-%{version}.tar.gz HEAD
#
# Fetch bundled deps (or let rpmbuild download Source1 if allowed):
#   spectool -g -R hambridge.spec
#
# Local build (from repo root, after placing sources under build/rpmbuild):
#   make fedora-rpm
#   make fedora-test   # build + smoke-test extracted binary
#   rpmbuild -ba --define "_topdir $(pwd)/build/rpmbuild" build/rpmbuild/SPECS/hambridge.spec
#
# COPR/Koji: list both sources in the dist-git lookaside; the MQTT zip avoids curl during %%build.

%global fpc_mqtt_tag     1.2
%global fpc_mqtt_sha256  702ded75607d2ba8429fffc3509bbb7607466be9596bc23d8bd73c13f8e74214

Name:           hambridge
Version:        0.3.3
Release:        1%{?dist}
Summary:        HaMBridge — Linux evdev to MQTT bridge (Free Pascal)

License:        GPL-3.0-or-later
# Set to your public clone URL when publishing the spec (COPR/SourceRPM metadata).
URL:            https://example.invalid/hambridge
# Tarball from `git archive` (see header comment). Bump Version when tagging releases.
Source0:        %{name}-%{version}.tar.gz
# Bundled build dependency (same pin as Makefile); offline-friendly for mock/koji.
Source1:       https://github.com/prof7bit/fpc-mqtt-client/archive/refs/tags/%{fpc_mqtt_tag}.zip#/fpc-mqtt-client-%{fpc_mqtt_tag}.zip

BuildRequires:  fpc
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  unzip
BuildRequires:  systemd-rpm-macros

Requires:       libevdev >= 1.5
Requires:       openssl-libs
Requires:       systemd

%description
HaMBridge publishes Linux input subsystem (evdev) events as JSON to an MQTT broker. v0.1 is
evdev→MQTT only; VISCA/serial phases are planned separately.

Configuration lives under /etc/hambridge/ (see %%doc examples). Install sysusers + tmpfiles
snippets, adjust udev rules for your hardware, then enable hambridge.service.


%prep
%setup -q -n %{name}-%{version}
mkdir -p build/deps
cp %{SOURCE1} "build/deps/fpc-mqtt-client-%{fpc_mqtt_tag}.zip"
echo '%{fpc_mqtt_sha256}  build/deps/fpc-mqtt-client-%{fpc_mqtt_tag}.zip' | sha256sum -c -


%build
# Makefile unpacks Source1 zip and links libevdev.so.2 from the build root.
%make_build


%install
install -Dpm0755 build/hambridge %{buildroot}%{_bindir}/hambridge

install -Dpm0644 packaging/systemd/hambridge.service \
  %{buildroot}%{_unitdir}/hambridge.service

install -Dpm0644 packaging/systemd/sysusers.d/hambridge.conf \
  %{buildroot}%{_sysusersdir}/hambridge.conf

install -Dpm0644 packaging/systemd/tmpfiles.d/hambridge.conf \
  %{buildroot}%{_tmpfilesdir}/hambridge.conf

install -Dpm0644 packaging/udev/70-hambridge-input.rules \
  %{buildroot}%{_udevrulesdir}/70-hambridge-input.rules


%post
%systemd_post hambridge.service

%preun
%systemd_preun hambridge.service

%postun
%systemd_postun_with_restart hambridge.service


%files
%license LICENSE
%doc README.md INSTALL.md DEVELOPING.md Specification.md ConfigurationGuide.md bridge.json.example devices.json.example

%{_bindir}/hambridge

%{_unitdir}/hambridge.service
%{_sysusersdir}/hambridge.conf
%{_tmpfilesdir}/hambridge.conf
%{_udevrulesdir}/70-hambridge-input.rules


%changelog
* Sat May 02 2026 HaMBridge packaging <packaging@local> - 0.1.0-1
- Initial RPM: hambridge binary, systemd unit, sysusers/tmpfiles/udev, doc + config examples.
