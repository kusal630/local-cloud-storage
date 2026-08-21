# Test Plan

## Automated Tests

### Unit Tests (`test/unit/`)
1. `file_names_test.dart` – File name sanitization, validation, and duplicate naming
2. `cipher_test.dart` – SHA-256 hashing, Argon2id password hashing, token generation, path guard

### Widget Tests (`test/widget/`)
1. `welcome_screen_test.dart` – Welcome screen renders app name and buttons
2. `common_widgets_test.dart` – EmptyState, ErrorState, LoadingIndicator, formatBytes

### Integration Tests (`test/integration/`)
1. `vault_integration_test.dart` – Vault creation, folder CRUD, circular move prevention, server health check

## Manual Test Cases

### Host Mode Flow
| # | Step | Expected Result |
|---|------|----------------|
| H1 | Open app, tap "Start Storage Node" | Host Setup screen appears |
| H2 | Tap storage location selector | File picker opens, can select folder |
| H3 | Enter device name and password | Fields accept input |
| H4 | Tap "Start Storage Node" | Host Dashboard appears with server running |
| H5 | Verify server URL is displayed | URL shown (e.g. http://192.168.x.x:8484) |
| H6 | Verify QR code is displayed | QR code image visible |
| H7 | Verify pairing code is displayed | 6-digit code shown |
| H8 | Tap "Regenerate" pairing code | New code appears |
| H9 | Check storage info on dashboard | Total, free, vault, trash sizes shown |
| H10 | Stop server | Server status changes to stopped |

### Client Mode Flow
| # | Step | Expected Result |
|---|------|----------------|
| C1 | Open app, tap "Connect to Storage Node" | Client Connect screen appears |
| C2 | Enter server URL and pairing code | Fields accept input |
| C3 | Tap "Connect" | Files screen appears (root folder) |
| C4 | Tap + then "New Folder" | Dialog appears, create folder |
| C5 | Verify folder appears in list | Folder listed with correct name |
| C6 | Tap + then "Upload File" | File picker opens |
| C7 | Select a file | Upload queued, transfer screen shows progress |
| C8 | Wait for upload to complete | File appears in file list |
| C9 | Tap file | Preview screen shows file metadata |
| C10 | Tap download | Download queued |
| C11 | Long-press file, tap Rename | Rename dialog, enter new name |
| C12 | Verify name updated | File shows new name |
| C13 | Long-press file, tap Move | Folder picker dialog |
| C14 | Select target folder, tap "Move Here" | File moved to target folder |
| C15 | Long-press file, tap Delete | Confirmation dialog |
| C16 | Confirm delete | File disappears from list |
| C17 | Go to Trash tab | Deleted file appears in trash |
| C18 | Tap restore on trashed item | Item restored, disappears from trash |
| C19 | Tap delete permanently on trash item | Item permanently deleted |
| C20 | Tap "Empty Trash" | All trash items permanently deleted |
| C21 | Go to Devices tab | Paired devices listed |
| C22 | Go to Storage tab | Disk usage shown |
| C23 | Go to Settings tab | Theme toggle, disconnect button visible |
| C24 | Toggle theme | App theme changes (light/dark) |
| C25 | Tap Disconnect | Returns to welcome screen |
| C26 | Search for a file | Search results appear |

### Upload/Download Verification
| # | Step | Expected Result |
|---|------|----------------|
| U1 | Upload a 10 MB file | Progress shown in Transfer Manager |
| U2 | Cancel during upload | Transfer cancelled |
| U3 | Retry failed upload | Upload restarts from beginning |
| D1 | Download file to local disk | File saved with correct content |
| D2 | Verify SHA-256 checksum | Checksum matches original file |
| D3 | Cancel during download | Transfer cancelled |

### Edge Cases
| # | Step | Expected Result |
|---|------|----------------|
| E1 | Upload file with duplicate name in same folder | Auto-renamed to "file (1).ext" |
| E2 | Create folder with same name as existing | Auto-renamed |
| E3 | Move folder into its own subfolder | Rejected with error |
| E4 | Delete root folder | Not allowed |
| E5 | Try to access with invalid token | 401 error, re-login required |
| E6 | Use expired pairing code | Rejected |
| E7 | Enter wrong password | Login fails |
| E8 | Network disconnected | Error message shown, retry available |

### Android-Specific
| # | Step | Expected Result |
|---|------|----------------|
| A1 | Install APK on Android device | App installs successfully |
| A2 | Grant camera permission for QR scan | Scanner opens |
| A3 | Scan host QR code | Server URL populated |
| A4 | Upload file from Android | Progress shown, file uploaded |
| A5 | Download file on Android | File saved to device storage |