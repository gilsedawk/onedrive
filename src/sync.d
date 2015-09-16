import core.exception: RangeError;
import std.algorithm, std.datetime, std.file, std.json, std.path, std.stdio;
import config, itemdb, onedrive, util;

private bool isItemFolder(const ref JSONValue item)
{
	scope (failure) return false;
	JSONValue folder = item["folder"];
	return true;
}

private bool isItemFile(const ref JSONValue item)
{
	scope (failure) return false;
	JSONValue folder = item["file"];
	return true;
}

private bool isItemDeleted(const ref JSONValue item)
{
	scope (failure) return false;
	return !item["deleted"].isNull();
}

private bool testCrc32(string path, const(char)[] crc32)
{
	if (crc32) {
		string localCrc32 = computeCrc32(path);
		if (crc32 == localCrc32) return true;
	}
	return false;
}

class SyncException: Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

final class SyncEngine
{
	private Config cfg;
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private bool verbose;
	private string statusToken;
	private string[] skippedItems;
	private string[] itemsToDelete;

	void delegate(string) onStatusToken;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, bool verbose)
	{
		assert(onedrive && itemdb);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.verbose = verbose;
	}

	void setStatusToken(string statusToken)
	{
		this.statusToken = statusToken;
	}

	void applyDifferences()
	{
		if (verbose) writeln("Applying differences ...");
		JSONValue changes;
		do {
			changes = onedrive.viewChangesByPath("/", statusToken);
			foreach (item; changes["value"].array) {
				applyDifference(item);
			}
			statusToken = changes["@changes.token"].str;
			onStatusToken(statusToken);
		} while (changes["@changes.hasMoreChanges"].type == JSON_TYPE.TRUE);
		// delete items in itemsToDelete
		deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	private void applyDifference(JSONValue item)
	{
		string id = item["id"].str;
		string name = item["name"].str;
		string eTag = item["eTag"].str;

		if (verbose) writeln(id, " ", name);

		Item cachedItem;
		bool cached = itemdb.selectById(id, cachedItem);

		if (cached && !isItemSynced(cachedItem)) {
			if (verbose) writeln("The local item is out of sync, renaming ...");
			safeRename(cachedItem.path);
			cached = false;
		}

		ItemType type;
		if (isItemDeleted(item)) {
			if (verbose) writeln("The item is marked for deletion");
			if (cached) applyDeleteItem(cachedItem);
			return;
		} else if (isItemFile(item)) {
			if (verbose) writeln("The item is a file");
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			if (verbose) writeln("The item is a directory");
			type = ItemType.dir;
		} else {
			if (verbose) writeln("The item is neither a file nor a directory");
			skippedItems ~= id;
			return;
		}

		string parentId = item["parentReference"].object["id"].str;
		if (skippedItems.find(parentId).length != 0) {
			if (verbose) writeln("The item is a children of a skipped item");
			skippedItems ~= id;
			return;
		}

		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"].object["lastModifiedDateTime"].str;

		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"].object["hashes"].object["crc32Hash"].str;
			} catch (JSONException e) {
				if (verbose) writeln("The hash is not available");
			} catch (RangeError e) {
				if (verbose) writeln("The crc32 hash is not available");
			}
		}

		Item newItem;
		itemdb.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
		itemdb.selectById(id, newItem);

		// TODO add item in the db anly if correctly downloaded
		try {
			if (!cached) {
				applyNewItem(newItem);
			} else {
				applyChangedItem(cachedItem, newItem);
			}
		} catch (SyncException e) {
			itemdb.deleteById(id);
			throw e;
		}
	}

	private void applyDeleteItem(Item item)
	{
		itemsToDelete ~= item.path;
		itemdb.deleteById(item.id);
	}

	private void applyNewItem(Item item)
	{
		assert(item.id);
		if (exists(item.path)) {
			if (isItemSynced(item)) {
				if (verbose) writeln("The item is already present");
				// ensure the modified time is correct
				setTimes(item.path, item.mtime, item.mtime);
				return;
			} else {
				if (verbose) writeln("The local item is out of sync, renaming ...");
				safeRename(item.path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			writeln("Downloading: ", item.path);
			try {
				onedrive.downloadById(item.id, item.path);
			} catch (OneDriveException e) {
				throw new SyncException("Sync error", e);
			}
			break;
		case ItemType.dir:
			writeln("Creating directory: ", item.path);
			mkdir(item.path);
			break;
		}
		setTimes(item.path, item.mtime, item.mtime);
	}

	private void applyChangedItem(Item oldItem, Item newItem)
	{
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);
		assert(exists(oldItem.path));

		if (oldItem.eTag != newItem.eTag) {
			if (oldItem.path != newItem.path) {
				writeln("Moving: ", oldItem.path, " -> ", newItem.path);
				if (exists(newItem.path)) {
					if (verbose) writeln("The destination is occupied, renaming ...");
					safeRename(newItem.path);
				}
				rename(oldItem.path, newItem.path);
			}
			if (newItem.type == ItemType.file && oldItem.cTag != newItem.cTag) {
				writeln("Downloading: ", newItem.path);
				onedrive.downloadById(newItem.id, newItem.path);
			}
			setTimes(newItem.path, newItem.mtime, newItem.mtime);
		} else {
			if (verbose) writeln("The item is not changed");
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(Item item)
	{
		if (!exists(item.path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(item.path)) {
				SysTime localModifiedTime = timeLastModified(item.path);
				import core.time: Duration;
				item.mtime.fracSecs = Duration.zero; // HACK
				if (localModifiedTime == item.mtime) {
					return true;
				} else {
					if (verbose) writeln("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
				}
				if (item.crc32) {
					string localCrc32 = computeCrc32(item.path);
					if (localCrc32 == item.crc32) {
						return true;
					} else {
						if (verbose) writeln("The local item has a different hash");
					}
				}
			} else {
				if (verbose) writeln("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
			if (isDir(item.path)) {
				return true;
			} else {
				if (verbose) writeln("The local item is a file but should be a directory");
			}
			break;
		}
		return false;
	}

	private void deleteItems()
	{
		if (verbose) writeln("Deleting files ...");
		foreach_reverse (path; itemsToDelete) {
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
					writeln("Deleted file: ", path);
				}
			} else {
				try {
					rmdir(path);
					writeln("Deleted dir: ", path);
				} catch (FileException e) {
					writeln("Keeping dir: ", path);
				}
			}
		}
		itemsToDelete.length = 0;
		assumeSafeAppend(itemsToDelete);
	}

	// scan the directory for unsynced files and upload them
	public void uploadDifferences()
	{
		if (verbose) writeln("Uploading differences ...");
		foreach (Item item; itemdb.selectAll()) {
			uploadDifference(item);
		}
		// check for new files or directories
		foreach (DirEntry entry; dirEntries(".", SpanMode.breadth, false)) {
			string path = entry.name[2 .. $]; // HACK: skip "./"
			Item item;
			if (!itemdb.selectByPath(path, item)) {
				if (entry.isDir) {
					uploadCreateDir(path);
				} else {
					uploadNewFile(path);
				 }
			}
		}
	}

	public void uploadDifferences(string path)
	{
		assert(isDir(path));
		Item item;
		foreach (DirEntry entry; dirEntries(path, SpanMode.breadth, false)) {
			if (itemdb.selectByPath(entry.name, item)) {
				uploadDifference(item);
			} else {
				uploadNewFile(entry.name);
			}
		}
	}

	private void uploadDifference(Item item)
	{
		if (verbose) writeln(item.id, " ", item.name);
		if (exists(item.path)) {
			final switch (item.type) {
			case ItemType.file:
				if (isFile(item.path)) {
					uploadItemDifferences(item);
				} else {
					if (verbose) writeln("The item was a file but now is a directory");
					uploadDeleteItem(item);
					uploadCreateDir(item.path);
				}
				break;
			case ItemType.dir:
				if (!isDir(item.path)) {
					if (verbose) writeln("The item was a directory but now is a file");
					uploadDeleteItem(item);
					uploadNewFile(item.path);
				} else {
					if (verbose) writeln("The item has not changed");
				}
				break;
			}
		} else {
			if (verbose) writeln("The item has been deleted");
			uploadDeleteItem(item);
		}
	}

	// check if the item is changed and upload the differences
	private void uploadItemDifferences(Item item)
	{
		SysTime localModifiedTime = timeLastModified(item.path);
		import core.time: Duration;
		item.mtime.fracSecs = Duration.zero; // HACK
		if (localModifiedTime != item.mtime) {
			if (verbose) writeln("The item last modified time has changed");
			string id = item.id;
			string eTag = item.eTag;
			if (item.type == ItemType.file && !testCrc32(item.path, item.crc32)) {
				if (verbose) writeln("The item content has changed");
				writeln("Uploading: ", item.path);
				auto res = onedrive.simpleUpload(item.path, item.path, item.eTag);
				saveItem(res);
				id = res["id"].str;
				eTag = res["eTag"].str;
			}
			uploadLastModifiedTime(id, eTag, localModifiedTime.toUTC());
		} else {
			if (verbose) writeln("The item has not changed");
		}
	}

	void uploadCreateDir(const(char)[] path)
	{
		writeln("Creating remote directory: ", path);
		JSONValue item = ["name": baseName(path).idup];
		item["folder"] = parseJSON("{}");
		auto res = onedrive.createByPath(dirName(path), item);
		saveItem(res);
	}

	private void uploadNewFile(string path)
	{
		writeln("Uploading: ", path);
		auto res = onedrive.simpleUpload(path, path);
		saveItem(res);
		string id = res["id"].str;
		string eTag = res["eTag"].str;
		uploadLastModifiedTime(id, eTag, timeLastModified(path).toUTC());
	}

	private void uploadDeleteItem(Item item)
	{
		writeln("Deleting remote: ", item.path);
		onedrive.deleteById(item.id, item.eTag);
		itemdb.deleteById(item.id);
	}

	private void uploadLastModifiedTime(const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		JSONValue mtimeJson = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
			])
		];
		auto res = onedrive.updateById(id, mtimeJson, eTag);
		saveItem(res);
	}

	private void saveItem(JSONValue item)
	{
		string id = item["id"].str;
		ItemType type;
		if (isItemFile(item)) {
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
		} else {
			assert(0);
		}
		string name = item["name"].str;
		string eTag = item["eTag"].str;
		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"].object["lastModifiedDateTime"].str;
		string parentId = item["parentReference"].object["id"].str;
		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"].object["hashes"].object["crc32Hash"].str;
			} catch (JSONException e) {
				// swallow exception
			} catch (RangeError e) {
				// swallow exception
			}
		}
		itemdb.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
	}

	// HACK
	void uploadDifference2(string path)
	{
		assert(isFile(path));
		Item item;
		if (itemdb.selectByPath(path, item)) {
			uploadDifference(item);
		} else {
			uploadNewFile(path);
		}
	}

	void moveItem(const(char)[] from, string to)
	{
		writeln("Moving ", from, " to ", to, " ...");
		Item item;
		if (!itemdb.selectByPath(from, item)) {
			throw new SyncException("Can't move a non synced item");
		}
		JSONValue diff = ["name": baseName(to)];
		diff["parentReference"] = JSONValue([
			"path": "/drive/root:/" ~ dirName(to)
		]);
		writeln(diff.toPrettyString());
		auto res = onedrive.updateById(item.id, diff, item.eTag);
		saveItem(res);
	}

	void deleteByPath(const(char)[] path)
	{
		writeln("Deleting: ", path);
		Item item;
		if (!itemdb.selectByPath(path, item)) {
			throw new SyncException("Can't delete a non synced item");
		}
		uploadDeleteItem(item);
	}
}
