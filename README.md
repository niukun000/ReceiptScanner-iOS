# 🧾 Welcome to the Receipt Scanner Project!

This guide is designed for Mac users who want to run this app but have **never used Xcode or written code.** Follow these simple steps to see the app in action!

---

## 🛠 Step 1: Install Xcode
To run this app on your Mac, you need Apple's development tool called **Xcode**.

1. Open the **App Store** on your Mac.
2. Search for **"Xcode"**.
3. Click **Get** or **Install**. 
4. Once installed, open Xcode. If it asks to install "Additional Components," click **Install**.

---

## 📂 Step 2: Open the Project
1. Open the folder named `ReceiptScanner-iOS` on your computer.
2. Open the sub-folder named `ReceiptScanner`.
3. Double-click the file named **`ReceiptScanner.xcodeproj`** (blue blueprint icon).

---

## 📱 Step 3: Choose Your Device
You have two choices: use a virtual phone on your screen, or your actual physical iPhone.

### Option A: Virtual iPhone (Easiest)
1. At the very top-middle of the Xcode window, click the button that says something like **"Any iOS Device"** or **"iPhone 15"**.
2. Scroll down to **"iOS Simulators"** and pick one (e.g., **iPhone 15 Pro**).

### Option B: Your Physical iPhone
1. **Connect your iPhone** to your Mac with a cable. 
2. If your iPhone asks to **"Trust This Computer?"**, tap **Trust** and enter your passcode.
3. **Set up Signing (Required for real phones):**
   - In Xcode, on the far left, click the **blue folder icon** at the very top.
   - Click the word **"ReceiptScanner"** at the very top of that list (it has a blue icon).
   - In the main middle area, click the **"Signing & Capabilities"** tab.
   - Look for **"Team"** and click **"Add Account..."**. Sign in with your Apple ID.
   - Once signed in, select your name in the **Team** dropdown menu.
4. **Select your phone:** Click the device button at the top-middle of Xcode and select your actual iPhone from the list.

---

## ▶️ Step 4: Run the App!
1. Click the **Play button** (▶️) in the top-left corner.
2. **If using a real iPhone:** 
   - The first time you run it, it might say "Untrusted Developer."
   - On your **iPhone**, go to **Settings** -> **General** -> **VPN & Device Management** (or Profiles).
   - Tap on your Apple ID and tap **"Trust"**.
3. The app will now launch on your device!

---

## ❓ Troubleshooting for Beginners

### "I see red errors!"
Go to the top menu and click **Product** -> **Clean Build Folder**, then try the **Play button** again.

### "Xcode says my Bundle Identifier is not unique"
In the same **Signing & Capabilities** tab where you picked your name, change the "Bundle Identifier" text (e.g., add a random number to the end of `com.example.ReceiptScanner`) and try again.

---

### 🎊 Success!
You've just launched the Receipt Scanner. Happy testing!
