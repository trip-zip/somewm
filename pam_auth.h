/*
 * pam_auth.h - PAM authentication for somewm lock screen
 */

#ifndef PAM_AUTH_H
#define PAM_AUTH_H

/**
 * Authenticate user via PAM.
 *
 * Uses the "login" PAM service to verify the password against
 * the current user's credentials.
 *
 * Security notes:
 * - Password is cleared from memory after verification
 * - Returns 0 (failure) if PAM is not available at compile time
 *
 * @param password The password to verify (will be cleared after use)
 * @return 1 if authentication successful, 0 if failed
 */
int pam_authenticate_user(const char *password);

#endif /* PAM_AUTH_H */
