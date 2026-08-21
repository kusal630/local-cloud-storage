import 'dart:io';

import 'package:disk_space/disk_space.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/path_guard.dart';
import '../database/vault_database.dart';
import '../models/storage_status.dart';
import '../models/vault_file.dart';
import '../repositories/blob_repository.dart';
import '../repositories/device_repository.dart';
import '../repositories/file_repository.dart';
import '../repositories/settings_repository.dart';
import '../repositories/upload_session_repository.dart';

/// The on-disk vault: `<storage>/.localvault` plus the SQLite database and all
/// repositories. All host-side storage operations go through this object.
class Vault {
  Vault._({
    required this.vaultDir,
    required this.database,
    required this.settings,
    required this.devices,
    required this.files,
    required this.blobs,
    required this.uploads,
  });

  factory Vault.from({
    required Directory vaultDir,
    required VaultDatabase database,
  }) {
    return Vault._(
      vaultDir: vaultDir,
      database: database,
      settings: SettingsRepository(database),
      devices: DeviceRepository(database),
      files: FileRepository(database),
      blobs: BlobRepository(database),
      uploads: UploadSessionRepository(database),
    );
  }

  final Directory vaultDir;
  final VaultDatabase database;
  final SettingsRepository settings;
  final DeviceRepository devices;
  final FileRepository files;
  final BlobRepository blobs;
  final UploadSessionRepository uploads;

  Directory get blobsDir =>
      Directory(p.join(vaultDir.path, AppConstants.blobsDirName));
  Directory get tmpDir =>
      Directory(p.join(vaultDir.path, AppConstants.tmpDirName));
  Directory get thumbsDir =>
      Directory(p.join(vaultDir.path, AppConstants.thumbsDirName));
  Directory get logsDir =>
      Directory(p.join(vaultDir.path, AppConstants.logsDirName));

  Directory get storageRoot => Directory(settings.storageRoot ?? vaultDir.parent.path);

  /// Creates the `.localvault` skeleton and opens the database.
  static Future<Vault> create(Directory storageRoot) async {
    await storageRoot.create(recursive: true);
    final vaultDir = Directory(
      p.join(storageRoot.path, AppConstants.vaultDirName),
    );
    await _ensureDirs(vaultDir);
    final database = VaultDatabase.open(vaultDir);
    final vault = Vault.from(vaultDir: vaultDir, database: database);
    vault.settings.storageRoot = storageRoot.path;
    logInfo('Vault created at ${vaultDir.path}');
    return vault;
  }

  /// Opens an existing vault without creating a new one.
  static Vault open(Directory storageRoot) {
    final vaultDir = Directory(
      p.join(storageRoot.path, AppConstants.vaultDirName),
    );
    if (!vaultDir.existsSync()) {
      throw const StorageException('No .localvault found in this location.');
    }
    final database = VaultDatabase.open(vaultDir);
    final vault = Vault.from(vaultDir: vaultDir, database: database);
    vault.settings.storageRoot ??= storageRoot.path;
    return vault;
  }

  static Future<void> _ensureDirs(Directory vaultDir) async {
    for (final name in [
      AppConstants.blobsDirName,
      AppConstants.tmpDirName,
      AppConstants.thumbsDirName,
      AppConstants.logsDirName,
    ]) {
      await Directory(p.join(vaultDir.path, name)).create(recursive: true);
    }
  }

  bool get isSetup => settings.setupComplete;

  Future<void> completeSetup({
    required String password,
    required String deviceName,
  }) async {
    if (password.isEmpty) {
      throw const ValidationException('Password cannot be empty.');
    }
    if (password.length < 6) {
      throw const ValidationException('Password must be at least 6 characters.');
    }
    final hash = await Cipher.hashPassword(password);
    settings.passwordHash = hash;
    settings.hostDeviceName = deviceName;
    settings.setupComplete = true;
  }

  Future<bool> verifyPassword(String password) async {
    final hash = settings.passwordHash;
    if (hash == null) return false;
    return Cipher.verifyPassword(password, hash);
  }

  // ---------------------------------------------------------------------------
  // Blob storage
  // ---------------------------------------------------------------------------

  File blobFile(BlobRecord record) =>
      File(PathGuard.resolveInside(vaultDir, record.relPath));

  File tmpFile(String uploadId) => File(
      PathGuard.resolveInside(vaultDir, '${AppConstants.tmpDirName}/$uploadId'));

  File thumbFile(String fileId) => File(PathGuard.resolveInside(
      vaultDir, '${AppConstants.thumbsDirName}/$fileId.png'));

  /// Moves an uploaded payload into blob storage (de-duplicating by
  /// checksum+size when possible).
  Future<BlobRecord> storeBlob({
    required String sourcePath,
    required int size,
    required String checksum,
    String? mimeType,
  }) async {
    final existing = blobs.findByChecksumAndSize(checksum, size);
    if (existing != null) {
      logInfo('Reusing existing blob ${existing.id} for checksum $checksum');
      return existing;
    }
    final id = const Uuid().v4();
    final relPath = PathGuard.blobRelativePath(id);
    final destDir = Directory(p.join(vaultDir.path, p.dirname(relPath)));
    await destDir.create(recursive: true);
    final dest = File(PathGuard.resolveInside(vaultDir, relPath));
    await File(sourcePath).rename(dest.path);
    return blobs.create(
      id: id,
      size: size,
      checksum: checksum,
      relPath: relPath,
      mime: mimeType,
    );
  }

  /// Deletes blob disk files that are no longer referenced by any file row.
  Future<void> deleteOrphanedBlobs(List<BlobRecord> orphans) async {
    for (final orphan in orphans) {
      try {
        final f = blobFile(orphan);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (e) {
        logWarn('Could not delete orphaned blob ${orphan.id}: $e');
      }
    }
  }

  /// Generates a small thumbnail for image files.
  Future<void> generateThumbnail(VaultFile file) async {
    if (file.type != FileRepository.typeFile || file.blobId == null) return;
    final mimeType = file.mime ?? mime.lookupMimeType(file.name);
    if (mimeType == null || !mimeType.startsWith('image/')) return;
    try {
      final blob = blobs.getById(file.blobId!);
      final src = blobFile(blob);
      final bytes = await src.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      final thumb = img.copyResize(decoded, width: 256);
      final out = thumbFile(file.id);
      await out.writeAsBytes(img.encodePng(thumb));
      files.setHasThumb(file.id, true);
    } catch (e) {
      logWarn('Thumbnail generation failed for ${file.id}: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Storage status
  // ---------------------------------------------------------------------------

  Future<StorageStatus> storageStatus() async {
    int total = 0;
    int free = 0;
    try {
      final totalValue = await DiskSpace.getTotalDiskSpace;
      final freeValue = await DiskSpace.getFreeDiskSpace;
      total = (totalValue ?? 0).round();
      free = (freeValue ?? 0).round();
    } catch (e) {
      logError('storageStatus: could not query disk space', e);
      throw StorageException('Storage is unavailable.', cause: e);
    }
    if (total <= 0) {
      throw const StorageException('Storage is unavailable.');
    }
    final usage = files.usage();
    return StorageStatus(
      total: total,
      free: free,
      used: total - free,
      vaultUsage: usage.vaultBytes,
      trashUsage: usage.trashBytes,
    );
  }

  void close() {
    try {
      database.close();
    } catch (_) {}
  }
}