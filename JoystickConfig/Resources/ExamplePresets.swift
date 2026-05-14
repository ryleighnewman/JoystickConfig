import Foundation

/// Built-in example presets for common games and desktop use cases.
/// These use the GCController extended gamepad mapping:
///   Axes: 0=LX, 1=LY, 2=RX, 3=RY, 4=LT, 5=RT
///   Buttons: 0=A/Cross, 1=B/Circle, 2=X/Square, 3=Y/Triangle,
///            4=LB, 5=RB, 6=LT(digital), 7=RT(digital),
///            8=Options/Share, 9=Menu/Start, 10=Home/PS,
///            11=L3, 12=R3
///   Hat 0: D-pad (U/D/L/R)
struct ExamplePresets {
    static var all: [Preset] {
        return [
            desktopNavigation,
            webBrowsing,
            mouseScroll,
            mediaController,
            presentationRemote,
            accessDesktopNavigation,
            accessWebBrowsing,
            adaptiveDesktop,
            minecraft,
            fortnite,
            fpsXbox,
            fpsPlayStation,
            fpsDualSense,
            racingGame,
        ]
    }

    // MARK: - Custom Desktop Navigation 1

    static var accessDesktopNavigation: Preset {
        parse("""
        {
            "name": "Custom Desktop Navigation",
            "tag": "Cursor, click, and macOS shortcuts",
            "joysticks": [{
                "tag": "Cursor, click, scroll, and macOS shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 14"],
                    "axi 0 +": ["mou 0 + 14"],
                    "axi 1 -": ["mou 1 - 14"],
                    "axi 1 +": ["mou 1 + 14"],
                    "axi 2 +": ["whe 0 + 4"],
                    "axi 2 -": ["whe 0 - 4"],
                    "axi 3 +": ["whe 1 + 4"],
                    "axi 3 -": ["whe 1 - 4"],
                    "axi 4 +": ["mbt 1"],
                    "axi 5 +": ["mbt 0"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["key 227", "key 6"],
                    "btn 3": ["key 227", "key 27"],
                    "btn 4": ["key 227", "key 43"],
                    "btn 5": ["key 227", "key 25"],
                    "hat 0 U": ["key 82"],
                    "hat 0 D": ["key 81"],
                    "hat 0 L": ["key 80"],
                    "hat 0 R": ["key 79"],
                    "btn 8": ["key 227", "key 44"],
                    "btn 9": ["key 40"]
                }
            }]
        }
        """)
    }

    // MARK: - Custom Web Browsing

    static var accessWebBrowsing: Preset {
        parse("""
        {
            "name": "Custom Web Browsing",
            "tag": "Browser navigation",
            "joysticks": [{
                "tag": "Cursor, scroll, tabs, and browser shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 14"],
                    "axi 0 +": ["mou 0 + 14"],
                    "axi 1 -": ["mou 1 - 14"],
                    "axi 1 +": ["mou 1 + 14"],
                    "axi 2 +": ["whe 0 + 5"],
                    "axi 2 -": ["whe 0 - 5"],
                    "axi 3 +": ["whe 1 + 5"],
                    "axi 3 -": ["whe 1 - 5"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["key 227", "key 26"],
                    "btn 3": ["key 227", "key 23"],
                    "btn 4": ["key 227", "key 54"],
                    "btn 5": ["key 227", "key 55"],
                    "axi 4 +": ["key 227", "key 55"],
                    "axi 5 +": ["key 227", "key 225", "key 55"],
                    "hat 0 U": ["key 82"],
                    "hat 0 D": ["key 81"],
                    "hat 0 L": ["key 80"],
                    "hat 0 R": ["key 79"],
                    "btn 8": ["key 227", "key 15"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - Custom Desktop Navigation 2

    static var adaptiveDesktop: Preset {
        parse("""
        {
            "name": "Alternate Desktop Layout",
            "tag": "Cursor, click, and shortcuts",
            "joysticks": [{
                "tag": "Cursor, click, scroll, and macOS shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 14"],
                    "axi 0 +": ["mou 0 + 14"],
                    "axi 1 -": ["mou 1 - 14"],
                    "axi 1 +": ["mou 1 + 14"],
                    "axi 2 +": ["whe 0 + 4"],
                    "axi 2 -": ["whe 0 - 4"],
                    "axi 3 +": ["whe 1 + 4"],
                    "axi 3 -": ["whe 1 - 4"],
                    "axi 4 +": ["mbt 1"],
                    "axi 5 +": ["mbt 0"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["key 41"],
                    "btn 2": ["key 227", "key 4"],
                    "btn 3": ["key 227", "key 29"],
                    "btn 4": ["key 227", "key 43"],
                    "btn 5": ["key 227", "key 225", "key 43"],
                    "hat 0 U": ["key 82"],
                    "hat 0 D": ["key 81"],
                    "hat 0 L": ["key 80"],
                    "hat 0 R": ["key 79"],
                    "btn 8": ["key 227", "key 44"],
                    "btn 9": ["key 40"]
                }
            }]
        }
        """)
    }

    // MARK: - Minecraft

    static var minecraft: Preset {
        parse("""
        {
            "name": "Minecraft",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "WASD + mouse look, triggers attack/place",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 20"],
                    "axi 2 -": ["mou 0 - 20"],
                    "axi 3 +": ["mou 1 + 14"],
                    "axi 3 -": ["mou 1 - 14"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 225"],
                    "btn 2": ["key 8"],
                    "btn 3": ["key 20"],
                    "btn 4": ["whs 1 -"],
                    "btn 5": ["whs 1 +"],
                    "btn 11": ["key 224"],
                    "btn 12": ["key 62"],
                    "hat 0 U": ["key 30"],
                    "hat 0 R": ["key 31"],
                    "hat 0 D": ["key 32"],
                    "hat 0 L": ["key 33"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - Fortnite

    static var fortnite: Preset {
        parse("""
        {
            "name": "Fortnite",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "WASD + aim, triggers shoot/ADS",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 10"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 27"],
                    "btn 4": ["key 20"],
                    "btn 5": ["key 8"],
                    "btn 11": ["key 225"],
                    "hat 0 U": ["key 30"],
                    "hat 0 R": ["key 31"],
                    "hat 0 D": ["key 32"],
                    "hat 0 L": ["key 33"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - FPS (Xbox)

    static var fpsXbox: Preset {
        parse("""
        {
            "name": "FPS (Xbox)",
            "tag": "Xbox controller",
            "joysticks": [{
                "tag": "Standard FPS layout",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 6"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - FPS (PlayStation)

    static var fpsPlayStation: Preset {
        parse("""
        {
            "name": "FPS (PlayStation)",
            "tag": "PS4 / PS5 controller",
            "joysticks": [{
                "tag": "Standard FPS layout",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 21"],
                    "btn 1": ["key 44"],
                    "btn 2": ["key 6"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """)
    }

    // MARK: - FPS (DualSense)

    static var fpsDualSense: Preset {
        parse("""
        {
            "name": "FPS (PS5 DualSense)",
            "tag": "PS5 DualSense controller",
            "joysticks": [{
                "tag": "DualSense FPS with touchpad",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 22"],
                    "axi 2 -": ["mou 0 - 22"],
                    "axi 3 +": ["mou 1 + 14"],
                    "axi 3 -": ["mou 1 - 14"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 224"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 25"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"],
                    "btn 13": ["key 8"]
                }
            }]
        }
        """)
    }

    // MARK: - Racing Game

    static var racingGame: Preset {
        parse("""
        {
            "name": "Racing Game",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "Steer + gas/brake on triggers",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 5 +": ["key 26"],
                    "axi 4 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 16"],
                    "axi 2 -": ["mou 0 - 16"],
                    "axi 3 +": ["mou 1 + 12"],
                    "axi 3 -": ["mou 1 - 12"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 225"],
                    "btn 2": ["key 8"],
                    "btn 3": ["key 21"],
                    "btn 4": ["key 20"],
                    "btn 5": ["key 9"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - Web Browsing

    static var webBrowsing: Preset {
        parse("""
        {
            "name": "Web Browsing",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "Mouse + scroll, browser shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 18"],
                    "axi 0 +": ["mou 0 + 18"],
                    "axi 1 -": ["mou 1 - 18"],
                    "axi 1 +": ["mou 1 + 18"],
                    "axi 2 +": ["whe 0 + 5"],
                    "axi 2 -": ["whe 0 - 5"],
                    "axi 3 +": ["whe 1 + 5"],
                    "axi 3 -": ["whe 1 - 5"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["key 227", "key 26"],
                    "btn 3": ["key 227", "key 23"],
                    "btn 4": ["key 227", "key 54"],
                    "btn 5": ["key 227", "key 55"],
                    "axi 4 +": ["key 227", "key 55"],
                    "axi 5 +": ["key 227", "key 225", "key 55"],
                    "btn 8": ["key 227", "key 15"],
                    "btn 9": ["key 227", "key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - Desktop Navigation

    static var desktopNavigation: Preset {
        parse("""
        {
            "name": "Desktop Navigation",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "Mouse + scroll, macOS shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 16"],
                    "axi 0 +": ["mou 0 + 16"],
                    "axi 1 -": ["mou 1 - 16"],
                    "axi 1 +": ["mou 1 + 16"],
                    "axi 2 +": ["whe 0 + 5"],
                    "axi 2 -": ["whe 0 - 5"],
                    "axi 3 +": ["whe 1 + 5"],
                    "axi 3 -": ["whe 1 - 5"],
                    "axi 4 +": ["mbt 1"],
                    "axi 5 +": ["mbt 0"],
                    "btn 0": ["key 227", "key 4"],
                    "btn 1": ["key 227", "key 29"],
                    "btn 2": ["key 227", "key 27"],
                    "btn 3": ["key 227", "key 25"],
                    "btn 4": ["key 227", "key 43"],
                    "btn 5": ["key 227", "key 225", "key 43"],
                    "hat 0 U": ["key 82"],
                    "hat 0 D": ["key 81"],
                    "hat 0 L": ["key 80"],
                    "hat 0 R": ["key 79"],
                    "btn 8": ["key 227", "key 44"],
                    "btn 9": ["key 40"]
                }
            }]
        }
        """)
    }

    // MARK: - Mouse + Scroll

    static var mouseScroll: Preset {
        parse("""
        {
            "name": "Mouse + Scroll",
            "tag": "Dual-analog joystick",
            "joysticks": [{
                "tag": "Left stick = cursor, right stick = scroll",
                "binds": {
                    "axi 0 -": ["mou 0 - 20"],
                    "axi 0 +": ["mou 0 + 20"],
                    "axi 1 -": ["mou 1 - 20"],
                    "axi 1 +": ["mou 1 + 20"],
                    "axi 2 -": ["whe 0 - 6"],
                    "axi 2 +": ["whe 0 + 6"],
                    "axi 3 -": ["whe 1 - 6"],
                    "axi 3 +": ["whe 1 + 6"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["mbt 2"],
                    "hat 0 L": ["mou 0 - 12"],
                    "hat 0 R": ["mou 0 + 12"],
                    "hat 0 U": ["mou 1 - 12"],
                    "hat 0 D": ["mou 1 + 12"]
                }
            }]
        }
        """)
    }

    // MARK: - Media Controller

    static var mediaController: Preset {
        parse("""
        {
            "name": "Media Controller",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "Play/pause, volume, track skip",
                "binds": {
                    "btn 0": ["key 232"],
                    "btn 1": ["key 233"],
                    "btn 2": ["key 234"],
                    "btn 3": ["key 235"],
                    "btn 4": ["key 237"],
                    "btn 5": ["key 238"],
                    "hat 0 U": ["key 128"],
                    "hat 0 D": ["key 129"],
                    "hat 0 L": ["key 130"],
                    "hat 0 R": ["key 131"],
                    "axi 1 -": ["key 128"],
                    "axi 1 +": ["key 129"],
                    "axi 0 -": ["key 130"],
                    "axi 0 +": ["key 131"],
                    "btn 8": ["key 41"]
                }
            }]
        }
        """)
    }

    // MARK: - Presentation Remote

    static var presentationRemote: Preset {
        parse("""
        {
            "name": "Presentation Remote",
            "tag": "Standard gamepad",
            "joysticks": [{
                "tag": "Slide navigation + pointer",
                "binds": {
                    "axi 0 -": ["mou 0 - 10"],
                    "axi 0 +": ["mou 0 + 10"],
                    "axi 1 -": ["mou 1 - 10"],
                    "axi 1 +": ["mou 1 + 10"],
                    "btn 0": ["key 79"],
                    "btn 1": ["key 80"],
                    "btn 2": ["key 44"],
                    "btn 3": ["key 5"],
                    "btn 4": ["mbt 0"],
                    "btn 5": ["mbt 1"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 62"]
                }
            }]
        }
        """)
    }

    // MARK: - Parser Helper

    private static func parse(_ json: String) -> Preset {
        guard let data = json.data(using: .utf8),
              let preset = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) else {
            return Preset(name: "Error", tag: "Failed to parse")
        }
        return preset
    }
}
