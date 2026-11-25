import Foundation
import NotchPrompterKit

extension ScriptLibrary {
    /// The practice script stays on this Mac: the iPhone has its own, in its own words.
    static let shared: ScriptLibrary = {
        let library = ScriptLibrary(welcome: { Script(title: welcomeTitle, text: welcomeText) },
                                    keepsLocal: { $0.text == welcomeText }, syncs: false)
        if case .recoveryRequired = library.saveState { return library }

        let samplesKey = "launchPracticeScriptsAdded"
        if !UserDefaults.standard.bool(forKey: samplesKey) {
            let samples = [(title: welcomeTitle, text: welcomeText)] + launchScripts
            for sample in samples.reversed() where !library.scripts.contains(where: { $0.title == sample.title }) {
                library.add(title: sample.title, text: sample.text, folder: "Practice")
            }
            if library.saveNow() { UserDefaults.standard.set(true, forKey: samplesKey) }
        }
        return library
    }()

    private static let launchScripts = [
        (title: "Practice · Product pitch", text: """
        [Look at the camera]

        We noticed customers were abandoning setup before they could see the value of the product.

        We narrowed the first session to one task and tested it with a small group. The next step is to compare activation and early retention against our baseline.

        [Pause]

        I'm asking for two weeks to validate the change before we expand the rollout.
        """),
        (title: "Practice · Video résumé", text: """
        Hi, I'm Sagar Paperwala. I'm a product manager focused on making complex customer workflows easier to use.

        [Pause]

        I turn customer feedback and product data into clear priorities, then work with design and engineering to ship and measure improvements.

        I'm looking for a team where I can own a customer problem from discovery through delivery.
        """),
        (title: "Practice · English (India)", text: """
        Hello, my name is Sagar. I’m speaking from Surat, Gujarat.

        Today I’ll share a short product update.

        We simplified the booking flow and asked customers to try it again.
        """),
        (title: "Practice · Line breaks", text: """
        Welcome to this short practice session.

        [Pause and take a breath]


        The next paragraph should appear without waiting for the blank lines.

        This is the final line of the test.
        """),
        (title: "Practice · Numbers and pauses", text: """
        Good morning. Our team reviewed twenty five bookings this week.

        [Pause]

        We resolved three urgent issues. I’ll share the results on Friday.
        """),
    ]

    static let welcomeTitle = "Start Here · Flicker Folio"

    static let welcomeText = """
    # Welcome to Flicker Folio

    I'm Sagar Paperwala. I built this for product pitches, video résumés, and recordings where looking down at a notepad breaks eye contact.

    [Look at the camera. Pause.]

    Open the prompter from the menu bar. Try Timed first and pick a comfortable reading speed. Press Space to pause, R to restart, or S to switch scripts.

    Conversational scrolls while you speak and slows when you pause. Follow My Words matches your live speech to the script when your Mac has the on-device language model.

    Open the Practice folder and try a Product pitch or a Video résumé. Then make a copy and replace the example with your own story.

    The app is free. Your scripts and recordings stay on this Mac.
    """
}
