(() => {
  const encodeBuffer = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  };

  const decodeBuffer = (value) => {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  };

  const creationOptions = (options) => {
    options.challenge = decodeBuffer(options.challenge);
    options.user.id = decodeBuffer(options.user.id);
    (options.excludeCredentials || []).forEach((item) => { item.id = decodeBuffer(item.id); });
    return options;
  };

  const requestOptions = (options) => {
    options.challenge = decodeBuffer(options.challenge);
    (options.allowCredentials || []).forEach((item) => { item.id = decodeBuffer(item.id); });
    return options;
  };

  const serializeCredential = (credential) => {
    const response = credential.response;
    const result = {
      id: credential.id,
      rawId: encodeBuffer(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: encodeBuffer(response.clientDataJSON)
      },
      clientExtensionResults: credential.getClientExtensionResults()
    };
    if (response.attestationObject) {
      result.response.attestationObject = encodeBuffer(response.attestationObject);
      if (response.getTransports) result.response.transports = response.getTransports();
    } else {
      result.response.authenticatorData = encodeBuffer(response.authenticatorData);
      result.response.signature = encodeBuffer(response.signature);
      result.response.userHandle = response.userHandle ? encodeBuffer(response.userHandle) : null;
    }
    return result;
  };

  const postJSON = async (url, body) => {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify(body)
    });
    const responseText = await response.text();
    let payload;
    try {
      payload = JSON.parse(responseText);
    } catch (_error) {
      throw new Error(`Server returned a non-JSON response (HTTP ${response.status}). Check the app terminal for the server error.`);
    }
    if (!response.ok) throw new Error(payload.error || "The request could not be completed.");
    return payload;
  };

  const status = document.getElementById("passkey-status");
  const showStatus = (message, isError = false) => {
    if (!status) return;
    status.textContent = message;
    status.classList.toggle("is-error", isError);
  };

  const loginButton = document.getElementById("passkey-login");
  if (loginButton) {
    loginButton.addEventListener("click", async () => {
      const email = document.getElementById("login-email").value.trim();
      if (!email) return showStatus("Enter your email address first.", true);
      if (!window.PublicKeyCredential || !navigator.credentials) return showStatus("Passkeys are not supported by this browser.", true);
      loginButton.disabled = true;
      showStatus("Waiting for your passkey…");
      try {
        const options = await postJSON("/passkeys/login/options", { email });
        const credential = await navigator.credentials.get({ publicKey: requestOptions(options) });
        const result = await postJSON("/passkeys/login", serializeCredential(credential));
        window.location.assign(result.redirect || "/directory");
      } catch (error) {
        showStatus(error.name === "NotAllowedError" ? "Passkey sign-in was cancelled." : error.message, true);
      } finally {
        loginButton.disabled = false;
      }
    });
  }

  const addForm = document.getElementById("add-passkey-form");
  if (addForm) {
    addForm.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!window.PublicKeyCredential || !navigator.credentials) return showStatus("Passkeys are not supported by this browser.", true);
      const button = addForm.querySelector("button[type=submit]");
      button.disabled = true;
      let stage = "Requesting passkey setup";
      showStatus("Follow your device’s prompts to create a passkey…");
      try {
        const current_password = document.getElementById("passkey-current-password").value;
        const options = await postJSON("/account/passkeys/options", { current_password });
        stage = "Opening Safari’s passkey prompt";
        const credential = await navigator.credentials.create({ publicKey: creationOptions(options) });
        stage = "Saving the passkey";
        const result = await postJSON("/account/passkeys", serializeCredential(credential));
        showStatus(result.message);
        window.location.reload();
      } catch (error) {
        const message = error.name === "NotAllowedError" ? "Passkey setup was cancelled." : `${stage}: ${error.name || "Error"}: ${error.message}`;
        showStatus(message, true);
      } finally {
        button.disabled = false;
      }
    });
  }
})();
