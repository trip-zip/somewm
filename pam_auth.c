/*
 * pam_auth.c - PAM authentication for somewm lock screen
 *
 * Provides password verification via PAM (Pluggable Authentication Modules).
 * Uses the "login" PAM service by default.
 *
 * Security considerations:
 * - Password is cleared from memory after PAM call
 * - PAM conversation function only responds to password prompts
 * - Uses volatile pointer to prevent compiler from optimizing away the clear
 */

#include "pam_auth.h"

#ifdef HAVE_PAM
#include <security/pam_appl.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pwd.h>

/* Thread-local storage for password during PAM conversation */
static __thread const char *pam_password = NULL;

/**
 * PAM conversation function - provides password when PAM asks for it.
 * Only responds to PAM_PROMPT_ECHO_OFF (password prompts).
 */
static int
pam_conversation(int num_msg, const struct pam_message **msg,
                 struct pam_response **resp, void *appdata_ptr)
{
    (void)appdata_ptr;  /* unused */

    /* Allocate response array */
    *resp = calloc(num_msg, sizeof(struct pam_response));
    if (*resp == NULL)
        return PAM_BUF_ERR;

    for (int i = 0; i < num_msg; i++) {
        switch (msg[i]->msg_style) {
        case PAM_PROMPT_ECHO_OFF:
            /* Password prompt - respond with the stored password */
            if (pam_password)
                (*resp)[i].resp = strdup(pam_password);
            else
                (*resp)[i].resp = strdup("");
            (*resp)[i].resp_retcode = 0;
            break;

        case PAM_PROMPT_ECHO_ON:
            /* Username or other visible prompt - we don't handle these */
            (*resp)[i].resp = strdup("");
            (*resp)[i].resp_retcode = 0;
            break;

        case PAM_ERROR_MSG:
        case PAM_TEXT_INFO:
            /* Informational messages - acknowledge but don't respond */
            (*resp)[i].resp = NULL;
            (*resp)[i].resp_retcode = 0;
            break;

        default:
            /* Unknown message type */
            free(*resp);
            *resp = NULL;
            return PAM_CONV_ERR;
        }
    }

    return PAM_SUCCESS;
}

/**
 * Clear password from memory securely.
 * Uses volatile to prevent compiler from optimizing away the writes.
 */
static void
secure_clear(char *ptr, size_t len)
{
    volatile char *p = (volatile char *)ptr;
    while (len--)
        *p++ = 0;
}

/**
 * Authenticate user via PAM.
 *
 * @param password The password to verify
 * @return 1 if authentication successful, 0 if failed
 */
int
pam_authenticate_user(const char *password)
{
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = { pam_conversation, NULL };
    const char *username;
    struct passwd *pw;
    int ret;

    /* Get current username */
    pw = getpwuid(getuid());
    if (pw == NULL || pw->pw_name == NULL)
        username = getenv("USER");
    else
        username = pw->pw_name;

    if (username == NULL)
        return 0;

    /* Store password for conversation function */
    pam_password = password;

    /* Initialize PAM */
    ret = pam_start("login", username, &conv, &pamh);
    if (ret != PAM_SUCCESS) {
        pam_password = NULL;
        return 0;
    }

    /* Authenticate */
    ret = pam_authenticate(pamh, 0);

    /* Cleanup */
    pam_end(pamh, ret);
    pam_password = NULL;

    /* Securely clear the password from caller's memory.
     * Note: We cast away const because we know the caller's buffer
     * should be cleared for security. */
    if (password) {
        size_t len = strlen(password);
        secure_clear((char *)password, len);
    }

    return ret == PAM_SUCCESS ? 1 : 0;
}

#else /* !HAVE_PAM */

/**
 * Fallback when PAM is not available - always fails.
 * This prevents unlock without proper authentication.
 */
int
pam_authenticate_user(const char *password)
{
    (void)password;  /* unused */
    return 0;
}

#endif /* HAVE_PAM */
