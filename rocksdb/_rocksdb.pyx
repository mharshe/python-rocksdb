import cython
from libcpp.string cimport string
from libcpp.deque cimport deque
from libcpp.vector cimport vector
from libcpp cimport bool as cpp_bool
from cython.operator cimport dereference as deref
from cpython.string cimport PyString_AsString
from cpython.string cimport PyString_Size
from cpython.string cimport PyString_FromString

from std_memory cimport shared_ptr
cimport options
cimport merge_operator
cimport filter_policy
cimport comparator
cimport slice_
cimport cache
cimport logger
cimport snapshot
cimport db
cimport iterator

from slice_ cimport slice_to_str
from slice_ cimport str_to_slice
from status cimport Status

from interfaces import MergeOperator as IMergeOperator
from interfaces import AssociativeMergeOperator as IAssociativeMergeOperator
from interfaces import FilterPolicy as IFilterPolicy
from interfaces import Comparator as IComparator
import traceback
import errors

cdef extern from "cpp/utils.hpp" namespace "py_rocks":
    cdef const slice_.Slice* vector_data(vector[slice_.Slice]&)

## Here comes the stuff to wrap the status to exception
cdef check_status(const Status& st):
    if st.ok():
        return

    if st.IsNotFound():
        raise errors.NotFound(st.ToString())

    if st.IsCorruption():
        raise errors.Corruption(st.ToString())

    if st.IsNotSupported():
        raise errors.NotSupported(st.ToString())

    if st.IsInvalidArgument():
        raise errors.InvalidArgument(st.ToString())

    if st.IsIOError():
        raise errors.RocksIOError(st.ToString())

    if st.IsMergeInProgress():
        raise errors.MergeInProgress(st.ToString())

    if st.IsIncomplete():
        raise errors.Incomplete(st.ToString())

    raise Exception("Unknown error: %s" % st.ToString())
######################################################


## Here comes the stuff for the comparator
@cython.internal
cdef class PyComparator(object):
    cdef object get_ob(self):
        return None

    cdef const comparator.Comparator* get_comparator(self):
        return NULL

@cython.internal
cdef class PyGenericComparator(PyComparator):
    cdef const comparator.Comparator* comparator_ptr
    cdef object ob

    def __cinit__(self, object ob):
        if not isinstance(ob, IComparator):
            # TODO: raise wrong subclass error
            raise TypeError("Cannot set comparator: %s" % ob)

        self.ob = ob
        self.comparator_ptr = <comparator.Comparator*>(
            new comparator.ComparatorWrapper(
                ob.name(),
                <void*>ob,
                compare_callback))

    def __dealloc__(self):
        del self.comparator_ptr

    cdef object get_ob(self):
        return self.ob

    cdef const comparator.Comparator* get_comparator(self):
        return self.comparator_ptr

@cython.internal
cdef class PyBytewiseComparator(PyComparator):
    cdef const comparator.Comparator* comparator_ptr

    def __cinit__(self):
        self.comparator_ptr = comparator.BytewiseComparator()

    def name(self):
        return PyString_FromString(self.comparator_ptr.Name())

    def compare(self, str a, str b):
        return self.comparator_ptr.Compare(
            str_to_slice(a),
            str_to_slice(b))

    cdef object get_ob(self):
       return self

    cdef const comparator.Comparator* get_comparator(self):
        return self.comparator_ptr

cdef int compare_callback(
    void* ctx,
    const slice_.Slice& a,
    const slice_.Slice& b) with gil:

    return (<object>ctx).compare(slice_to_str(a), slice_to_str(b))

BytewiseComparator = PyBytewiseComparator
#########################################



## Here comes the stuff for the filter policy
@cython.internal
cdef class PyFilterPolicy(object):
    cdef object get_ob(self):
        return None

    cdef const filter_policy.FilterPolicy* get_policy(self):
        return NULL

@cython.internal
cdef class PyGenericFilterPolicy(PyFilterPolicy):
    cdef filter_policy.FilterPolicy* policy
    cdef object ob

    def __cinit__(self, object ob):
        if not isinstance(ob, IFilterPolicy):
            raise TypeError("Cannot set filter policy: %s" % ob)

        self.ob = ob
        self.policy = <filter_policy.FilterPolicy*> new filter_policy.FilterPolicyWrapper(
                ob.name(),
                <void*>ob,
                <void*>ob,
                create_filter_callback,
                key_may_match_callback)

    def __dealloc__(self):
        del self.policy

    cdef object get_ob(self):
        return self.ob

    cdef const filter_policy.FilterPolicy* get_policy(self):
        return self.policy

cdef void create_filter_callback(
    void* ctx,
    const slice_.Slice* keys,
    int n,
    string* dst) with gil:

    cdef string ret = (<object>ctx).create_filter(
        [slice_to_str(keys[i]) for i in range(n)])
    dst.append(ret)

cdef cpp_bool key_may_match_callback(
    void* ctx,
    const slice_.Slice& key,
    const slice_.Slice& filt) with gil:

    return (<object>ctx).key_may_match(slice_to_str(key), slice_to_str(filt))

@cython.internal
cdef class PyBloomFilterPolicy(PyFilterPolicy):
    cdef const filter_policy.FilterPolicy* policy

    def __cinit__(self, int bits_per_key):
        self.policy = filter_policy.NewBloomFilterPolicy(bits_per_key)

    def __dealloc__(self):
        del self.policy

    def name(self):
        return PyString_FromString(self.policy.Name())

    def create_filter(self, keys):
        cdef string dst
        cdef vector[slice_.Slice] c_keys

        for key in keys:
            c_keys.push_back(str_to_slice(key))

        self.policy.CreateFilter(
            vector_data(c_keys),
            c_keys.size(),
            cython.address(dst))

        return dst

    def key_may_match(self, key, filter_):
        return self.policy.KeyMayMatch(
            str_to_slice(key),
            str_to_slice(filter_))

    cdef object get_ob(self):
        return self

    cdef const filter_policy.FilterPolicy* get_policy(self):
        return self.policy

BloomFilterPolicy = PyBloomFilterPolicy
#############################################



## Here comes the stuff for the merge operator
@cython.internal
cdef class PyMergeOperator(object):
    cdef shared_ptr[merge_operator.MergeOperator] merge_op
    cdef object ob

    def __cinit__(self, object ob):
        if isinstance(ob, IAssociativeMergeOperator):
            self.ob = ob
            self.merge_op.reset(
                <merge_operator.MergeOperator*>
                    new merge_operator.AssociativeMergeOperatorWrapper(
                        ob.name(),
                        <void*>(ob),
                        merge_callback))

        elif isinstance(ob, IMergeOperator):
            self.ob = ob
            self.merge_op.reset(
                <merge_operator.MergeOperator*>
                    new merge_operator.MergeOperatorWrapper(
                        ob.name(),
                        <void*>ob,
                        <void*>ob,
                        full_merge_callback,
                        partial_merge_callback))
        else:
            raise TypeError("Cannot set MergeOperator: %s" % ob)

    cdef object get_ob(self):
        return self.ob

    cdef shared_ptr[merge_operator.MergeOperator] get_operator(self):
        return self.merge_op

cdef cpp_bool merge_callback(
    void* ctx,
    const slice_.Slice& key,
    const slice_.Slice* existing_value,
    const slice_.Slice& value,
    string* new_value,
    logger.Logger* log) with gil:

    if existing_value == NULL:
        py_existing_value = None
    else:
        py_existing_value = slice_to_str(deref(existing_value))

    try:
        ret = (<object>ctx).merge(
            slice_to_str(key),
            py_existing_value,
            slice_to_str(value))

        if ret[0]:
            new_value.assign(
                PyString_AsString(ret[1]),
                PyString_Size(ret[1]))
            return True
        return False

    except Exception:
        tb = traceback.format_exc()
        logger.Log(
            log,
            "Error in merge_callback: %s",
            <bytes>tb)
        return False

cdef cpp_bool full_merge_callback(
    void* ctx,
    const slice_.Slice& key,
    const slice_.Slice* existing_value,
    const deque[string]& operand_list,
    string* new_value,
    logger.Logger* log) with gil:

    if existing_value == NULL:
        py_existing_value = None
    else:
        py_existing_value = slice_to_str(deref(existing_value))

    try:
        ret = (<object>ctx).full_merge(
            slice_to_str(key),
            py_existing_value,
            [operand_list[i] for i in range(operand_list.size())])

        if ret[0]:
            new_value.assign(
                PyString_AsString(ret[1]),
                PyString_Size(ret[1]))
            return True
        return False

    except Exception:
        tb = traceback.format_exc()
        logger.Log(
            log,
            "Error in full_merge_callback: %s",
            <bytes>tb)
        return False

cdef cpp_bool partial_merge_callback(
    void* ctx,
    const slice_.Slice& key,
    const slice_.Slice& left_op,
    const slice_.Slice& right_op,
    string* new_value,
    logger.Logger* log) with gil:

    try:
        ret = (<object>ctx).partial_merge(
            slice_to_str(key),
            slice_to_str(left_op),
            slice_to_str(right_op))

        if ret[0]:
            new_value.assign(
                PyString_AsString(ret[1]),
                PyString_Size(ret[1]))
            return True
        return False

    except Exception:
        tb = traceback.format_exc()
        logger.Log(
            log,
            "Error in partial_merge_callback: %s",
            <bytes>tb)

        return False
##############################################

#### Here comes the Cache stuff
@cython.internal
cdef class PyCache(object):
    cdef object get_ob(self):
        return None

    cdef shared_ptr[cache.Cache] get_cache(self):
        return shared_ptr[cache.Cache]()

@cython.internal
cdef class PyLRUCache(PyCache):
    cdef shared_ptr[cache.Cache] cache_ob

    def __cinit__(self, capacity, shard_bits=None, rm_scan_count_limit=None):
        if shard_bits is not None:
            if rm_scan_count_limit is not None:
                self.cache_ob = cache.NewLRUCache(
                    capacity,
                    shard_bits,
                    rm_scan_count_limit)
            else:
                self.cache_ob = cache.NewLRUCache(capacity, shard_bits)
        else:
            self.cache_ob = cache.NewLRUCache(capacity)

    cdef object get_ob(self):
        return self

    cdef shared_ptr[cache.Cache] get_cache(self):
        return self.cache_ob

LRUCache = PyLRUCache
###############################


cdef class CompressionType(object):
    no_compression = 'no_compression'
    snappy_compression = 'snappy_compression'
    zlib_compression = 'zlib_compression'
    bzip2_compression = 'bzip2_compression'

cdef class Options(object):
    cdef options.Options* opts
    cdef PyComparator py_comparator
    cdef PyMergeOperator py_merge_operator
    cdef PyFilterPolicy py_filter_policy
    cdef PyCache py_block_cache
    cdef PyCache py_block_cache_compressed

    def __cinit__(self):
        self.opts = new options.Options()

    def __dealloc__(self):
        del self.opts

    def __init__(self, **kwargs):
        self.py_comparator = BytewiseComparator()
        self.py_merge_operator = None
        self.py_filter_policy = None
        self.py_block_cache = None
        self.py_block_cache_compressed = None

        for key, value in kwargs.items():
            setattr(self, key, value)

    property create_if_missing:
        def __get__(self):
            return self.opts.create_if_missing
        def __set__(self, value):
            self.opts.create_if_missing = value

    property error_if_exists:
        def __get__(self):
            return self.opts.error_if_exists
        def __set__(self, value):
            self.opts.error_if_exists = value

    property paranoid_checks:
        def __get__(self):
            return self.opts.paranoid_checks
        def __set__(self, value):
            self.opts.paranoid_checks = value

    property write_buffer_size:
        def __get__(self):
            return self.opts.write_buffer_size
        def __set__(self, value):
            self.opts.write_buffer_size = value

    property max_write_buffer_number:
        def __get__(self):
            return self.opts.max_write_buffer_number
        def __set__(self, value):
            self.opts.max_write_buffer_number = value

    property min_write_buffer_number_to_merge:
        def __get__(self):
            return self.opts.min_write_buffer_number_to_merge
        def __set__(self, value):
            self.opts.min_write_buffer_number_to_merge = value

    property max_open_files:
        def __get__(self):
            return self.opts.max_open_files
        def __set__(self, value):
            self.opts.max_open_files = value

    property block_size:
        def __get__(self):
            return self.opts.block_size
        def __set__(self, value):
            self.opts.block_size = value

    property block_restart_interval:
        def __get__(self):
            return self.opts.block_restart_interval
        def __set__(self, value):
            self.opts.block_restart_interval = value

    property compression:
        def __get__(self):
            if self.opts.compression == options.kNoCompression:
                return CompressionType.no_compression
            elif self.opts.compression  == options.kSnappyCompression:
                return CompressionType.snappy_compression
            elif self.opts.compression == options.kZlibCompression:
                return CompressionType.zlib_compression
            elif self.opts.compression == options.kBZip2Compression:
                return CompressionType.bzip2_compression
            else:
                raise Exception("Unknonw type: %s" % self.opts.compression)

        def __set__(self, value):
            if value == CompressionType.no_compression:
                self.opts.compression = options.kNoCompression
            elif value == CompressionType.snappy_compression:
                self.opts.compression = options.kSnappyCompression
            elif value == CompressionType.zlib_compression:
                self.opts.compression = options.kZlibCompression
            elif value == CompressionType.bzip2_compression:
                self.opts.compression = options.kBZip2Compression
            else:
                raise TypeError("Unknown compression: %s" % value)

    property whole_key_filtering:
        def __get__(self):
            return self.opts.whole_key_filtering
        def __set__(self, value):
            self.opts.whole_key_filtering = value

    property num_levels:
        def __get__(self):
            return self.opts.num_levels
        def __set__(self, value):
            self.opts.num_levels = value

    property level0_file_num_compaction_trigger:
        def __get__(self):
            return self.opts.level0_file_num_compaction_trigger
        def __set__(self, value):
            self.opts.level0_file_num_compaction_trigger = value

    property level0_slowdown_writes_trigger:
        def __get__(self):
            return self.opts.level0_slowdown_writes_trigger
        def __set__(self, value):
            self.opts.level0_slowdown_writes_trigger = value

    property level0_stop_writes_trigger:
        def __get__(self):
            return self.opts.level0_stop_writes_trigger
        def __set__(self, value):
            self.opts.level0_stop_writes_trigger = value

    property max_mem_compaction_level:
        def __get__(self):
            return self.opts.max_mem_compaction_level
        def __set__(self, value):
            self.opts.max_mem_compaction_level = value

    property target_file_size_base:
        def __get__(self):
            return self.opts.target_file_size_base
        def __set__(self, value):
            self.opts.target_file_size_base = value

    property target_file_size_multiplier:
        def __get__(self):
            return self.opts.target_file_size_multiplier
        def __set__(self, value):
            self.opts.target_file_size_multiplier = value

    property max_bytes_for_level_base:
        def __get__(self):
            return self.opts.max_bytes_for_level_base
        def __set__(self, value):
            self.opts.max_bytes_for_level_base = value

    property max_bytes_for_level_multiplier:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier = value

    property max_bytes_for_level_multiplier_additional:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier_additional
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier_additional = value

    property expanded_compaction_factor:
        def __get__(self):
            return self.opts.expanded_compaction_factor
        def __set__(self, value):
            self.opts.expanded_compaction_factor = value

    property source_compaction_factor:
        def __get__(self):
            return self.opts.source_compaction_factor
        def __set__(self, value):
            self.opts.source_compaction_factor = value

    property max_grandparent_overlap_factor:
        def __get__(self):
            return self.opts.max_grandparent_overlap_factor
        def __set__(self, value):
            self.opts.max_grandparent_overlap_factor = value

    property disable_data_sync:
        def __get__(self):
            return self.opts.disableDataSync
        def __set__(self, value):
            self.opts.disableDataSync = value

    property use_fsync:
        def __get__(self):
            return self.opts.use_fsync
        def __set__(self, value):
            self.opts.use_fsync = value

    property db_stats_log_interval:
        def __get__(self):
            return self.opts.db_stats_log_interval
        def __set__(self, value):
            self.opts.db_stats_log_interval = value

    property db_log_dir:
        def __get__(self):
            return self.opts.db_log_dir
        def __set__(self, value):
            self.opts.db_log_dir = value

    property wal_dir:
        def __get__(self):
            return self.opts.wal_dir
        def __set__(self, value):
            self.opts.wal_dir = value

    property disable_seek_compaction:
        def __get__(self):
            return self.opts.disable_seek_compaction
        def __set__(self, value):
            self.opts.disable_seek_compaction = value

    property delete_obsolete_files_period_micros:
        def __get__(self):
            return self.opts.delete_obsolete_files_period_micros
        def __set__(self, value):
            self.opts.delete_obsolete_files_period_micros = value

    property max_background_compactions:
        def __get__(self):
            return self.opts.max_background_compactions
        def __set__(self, value):
            self.opts.max_background_compactions = value

    property max_background_flushes:
        def __get__(self):
            return self.opts.max_background_flushes
        def __set__(self, value):
            self.opts.max_background_flushes = value

    property max_log_file_size:
        def __get__(self):
            return self.opts.max_log_file_size
        def __set__(self, value):
            self.opts.max_log_file_size = value

    property log_file_time_to_roll:
        def __get__(self):
            return self.opts.log_file_time_to_roll
        def __set__(self, value):
            self.opts.log_file_time_to_roll = value

    property keep_log_file_num:
        def __get__(self):
            return self.opts.keep_log_file_num
        def __set__(self, value):
            self.opts.keep_log_file_num = value

    property soft_rate_limit:
        def __get__(self):
            return self.opts.soft_rate_limit
        def __set__(self, value):
            self.opts.soft_rate_limit = value

    property hard_rate_limit:
        def __get__(self):
            return self.opts.hard_rate_limit
        def __set__(self, value):
            self.opts.hard_rate_limit = value

    property rate_limit_delay_max_milliseconds:
        def __get__(self):
            return self.opts.rate_limit_delay_max_milliseconds
        def __set__(self, value):
            self.opts.rate_limit_delay_max_milliseconds = value

    property max_manifest_file_size:
        def __get__(self):
            return self.opts.max_manifest_file_size
        def __set__(self, value):
            self.opts.max_manifest_file_size = value

    property no_block_cache:
        def __get__(self):
            return self.opts.no_block_cache
        def __set__(self, value):
            self.opts.no_block_cache = value

    property table_cache_numshardbits:
        def __get__(self):
            return self.opts.table_cache_numshardbits
        def __set__(self, value):
            self.opts.table_cache_numshardbits = value

    property table_cache_remove_scan_count_limit:
        def __get__(self):
            return self.opts.table_cache_remove_scan_count_limit
        def __set__(self, value):
            self.opts.table_cache_remove_scan_count_limit = value

    property arena_block_size:
        def __get__(self):
            return self.opts.arena_block_size
        def __set__(self, value):
            self.opts.arena_block_size = value

    property disable_auto_compactions:
        def __get__(self):
            return self.opts.disable_auto_compactions
        def __set__(self, value):
            self.opts.disable_auto_compactions = value

    property wal_ttl_seconds:
        def __get__(self):
            return self.opts.WAL_ttl_seconds
        def __set__(self, value):
            self.opts.WAL_ttl_seconds = value

    property wal_size_limit_mb:
        def __get__(self):
            return self.opts.WAL_size_limit_MB
        def __set__(self, value):
            self.opts.WAL_size_limit_MB = value

    property manifest_preallocation_size:
        def __get__(self):
            return self.opts.manifest_preallocation_size
        def __set__(self, value):
            self.opts.manifest_preallocation_size = value

    property purge_redundant_kvs_while_flush:
        def __get__(self):
            return self.opts.purge_redundant_kvs_while_flush
        def __set__(self, value):
            self.opts.purge_redundant_kvs_while_flush = value

    property allow_os_buffer:
        def __get__(self):
            return self.opts.allow_os_buffer
        def __set__(self, value):
            self.opts.allow_os_buffer = value

    property allow_mmap_reads:
        def __get__(self):
            return self.opts.allow_mmap_reads
        def __set__(self, value):
            self.opts.allow_mmap_reads = value

    property allow_mmap_writes:
        def __get__(self):
            return self.opts.allow_mmap_writes
        def __set__(self, value):
            self.opts.allow_mmap_writes = value

    property is_fd_close_on_exec:
        def __get__(self):
            return self.opts.is_fd_close_on_exec
        def __set__(self, value):
            self.opts.is_fd_close_on_exec = value

    property skip_log_error_on_recovery:
        def __get__(self):
            return self.opts.skip_log_error_on_recovery
        def __set__(self, value):
            self.opts.skip_log_error_on_recovery = value

    property stats_dump_period_sec:
        def __get__(self):
            return self.opts.stats_dump_period_sec
        def __set__(self, value):
            self.opts.stats_dump_period_sec = value

    property block_size_deviation:
        def __get__(self):
            return self.opts.block_size_deviation
        def __set__(self, value):
            self.opts.block_size_deviation = value

    property advise_random_on_open:
        def __get__(self):
            return self.opts.advise_random_on_open
        def __set__(self, value):
            self.opts.advise_random_on_open = value

    property use_adaptive_mutex:
        def __get__(self):
            return self.opts.use_adaptive_mutex
        def __set__(self, value):
            self.opts.use_adaptive_mutex = value

    property bytes_per_sync:
        def __get__(self):
            return self.opts.bytes_per_sync
        def __set__(self, value):
            self.opts.bytes_per_sync = value

    property filter_deletes:
        def __get__(self):
            return self.opts.filter_deletes
        def __set__(self, value):
            self.opts.filter_deletes = value

    property max_sequential_skip_in_iterations:
        def __get__(self):
            return self.opts.max_sequential_skip_in_iterations
        def __set__(self, value):
            self.opts.max_sequential_skip_in_iterations = value

    property inplace_update_support:
        def __get__(self):
            return self.opts.inplace_update_support
        def __set__(self, value):
            self.opts.inplace_update_support = value

    property inplace_update_num_locks:
        def __get__(self):
            return self.opts.inplace_update_num_locks
        def __set__(self, value):
            self.opts.inplace_update_num_locks = value

    property comparator:
        def __get__(self):
            return self.py_comparator.get_ob()

        def __set__(self, value):
            if isinstance(value, PyComparator):
                if (<PyComparator?>value).get_comparator() == NULL:
                    raise Exception("Cannot set %s as comparator" % value)
                else:
                    self.py_comparator = value
            else:
                self.py_comparator = PyGenericComparator(value)

            self.opts.comparator = self.py_comparator.get_comparator()

    property merge_operator:
        def __get__(self):
            if self.py_merge_operator is None:
                return None
            return self.py_merge_operator.get_ob()

        def __set__(self, value):
            self.py_merge_operator = PyMergeOperator(value)
            self.opts.merge_operator = self.py_merge_operator.get_operator()

    property filter_policy:
        def __get__(self):
            if self.py_filter_policy is None:
                return None
            return self.py_filter_policy.get_ob()

        def __set__(self, value):
            if isinstance(value, PyFilterPolicy):
                if (<PyFilterPolicy?>value).get_policy() == NULL:
                    raise Exception("Cannot set filter policy: %s" % value)
                self.py_filter_policy = value
            else:
                self.py_filter_policy = PyGenericFilterPolicy(value)

            self.opts.filter_policy = self.py_filter_policy.get_policy()

    property block_cache:
        def __get__(self):
            if self.py_block_cache is None:
                return None
            return self.py_block_cache.get_ob()

        def __set__(self, value):
            if value is None:
                self.py_block_cache = None
                self.opts.block_cache.reset()
            else:
                if not isinstance(value, PyCache):
                    raise TypeError("%s is not a Cache" % value)

                self.py_block_cache = value
                self.opts.block_cache = self.py_block_cache.get_cache()

    property block_cache_compressed:
        def __get__(self):
            if self.py_block_cache_compressed is None:
                return None
            return self.py_block_cache_compressed.get_ob()

        def __set__(self, value):
            if value is None:
                self.py_block_cache_compressed = None
                self.opts.block_cache_compressed.reset()
                return

            if not isinstance(value, PyCache):
                raise TypeError("%s is not a Cache" % value)

            self.py_block_cache_compressed = value
            self.opts.block_cache_compressed = (<PyCache>value).get_cache()

# Forward declaration
cdef class Snapshot

cdef class KeysIterator
cdef class ValuesIterator
cdef class ItemsIterator
cdef class ReversedIterator

cdef class WriteBatch(object):
    cdef db.WriteBatch* batch

    def __cinit__(self, data=None):
        if data is not None:
            self.batch = new db.WriteBatch(data)
        else:
            self.batch = new db.WriteBatch()

    def __dealloc__(self):
        del self.batch

    def put(self, key, value):
        self.batch.Put(str_to_slice(key), str_to_slice(value))

    def merge(self, key, value):
        self.batch.Merge(str_to_slice(key), str_to_slice(value))

    def delete(self, key):
        self.batch.Delete(str_to_slice(key))

    def clear(self):
        self.batch.Clear()

    def data(self):
        return self.batch.Data()

    def count(self):
        return self.batch.Count()

cdef class DB(object):
    cdef Options opts
    cdef db.DB* db

    def __cinit__(self, db_name, Options opts, read_only=False):
        if read_only:
            check_status(
                db.DB_OpenForReadOnly(
                    deref(opts.opts),
                    db_name,
                    cython.address(self.db),
                    False))
        else:
            check_status(
                db.DB_Open(
                    deref(opts.opts),
                    db_name,
                    cython.address(self.db)))

        self.opts = opts

    def __dealloc__(self):
        del self.db

    def put(self, key, value, sync=False, disable_wal=False):
        cdef options.WriteOptions opts
        opts.sync = sync
        opts.disableWAL = disable_wal

        check_status(
            self.db.Put(opts, str_to_slice(key), str_to_slice(value)))

    def delete(self, key, sync=False, disable_wal=False):
        cdef options.WriteOptions opts
        opts.sync = sync
        opts.disableWAL = disable_wal

        check_status(
            self.db.Delete(opts, str_to_slice(key)))

    def merge(self, key, value, sync=False, disable_wal=False):
        cdef options.WriteOptions opts
        opts.sync = sync
        opts.disableWAL = disable_wal

        check_status(
            self.db.Merge(opts, str_to_slice(key), str_to_slice(value)))

    def write(self, WriteBatch batch, sync=False, disable_wal=False):
        cdef options.WriteOptions opts
        opts.sync = sync
        opts.disableWAL = disable_wal

        check_status(
            self.db.Write(opts, batch.batch))

    def get(self, key, *args, **kwargs):
        cdef string res
        cdef Status st

        st = self.db.Get(
            self.build_read_opts(self.__parse_read_opts(*args, **kwargs)),
            str_to_slice(key),
            cython.address(res))

        if st.ok():
            return res
        elif st.IsNotFound():
            return None
        else:
            check_status(st)

    def multi_get(self, keys, *args, **kwargs):
        cdef vector[string] values
        values.resize(len(keys))

        cdef vector[slice_.Slice] c_keys
        for key in keys:
            c_keys.push_back(str_to_slice(key))

        cdef vector[Status] res = self.db.MultiGet(
            self.build_read_opts(self.__parse_read_opts(*args, **kwargs)),
            c_keys,
            cython.address(values))

        cdef dict ret_dict = {}
        for index in range(len(keys)):
            if res[index].ok():
                ret_dict[keys[index]] = values[index]
            elif res[index].IsNotFound():
                ret_dict[keys[index]] = None
            else:
                check_status(res[index])

        return ret_dict

    def key_may_exist(self, key, fetch=False, *args, **kwargs):
        cdef string value
        cdef cpp_bool value_found
        cdef cpp_bool exists
        cdef options.ReadOptions opts
        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))

        if fetch:
            value_found = False
            exists = self.db.KeyMayExist(
                opts,
                str_to_slice(key),
                cython.address(value),
                cython.address(value_found))

            if exists:
                if value_found:
                    return (True, value)
                else:
                    return (True, None)
            else:
                return (False, None)
        else:
            exists = self.db.KeyMayExist(
                opts,
                str_to_slice(key),
                cython.address(value))

            return (exists, None)

    def iterkeys(self, prefix=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef KeysIterator it
        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))
        it = KeysIterator(self)
        it.ptr = self.db.NewIterator(opts)
        return it

    def itervalues(self, prefix=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef ValuesIterator it
        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))
        it = ValuesIterator(self)
        it.ptr = self.db.NewIterator(opts)
        return it

    def iteritems(self, prefix=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef ItemsIterator it
        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))
        it = ItemsIterator(self)
        it.ptr = self.db.NewIterator(opts)
        return it

    def snapshot(self):
        return Snapshot(self)

    def get_property(self, prop):
        cdef string value

        if self.db.GetProperty(str_to_slice(prop), cython.address(value)):
            return value
        else:
            return None

    def get_live_files_metadata(self):
        cdef vector[db.LiveFileMetaData] metadata

        self.db.GetLiveFilesMetaData(cython.address(metadata))

        ret = []
        for ob in metadata:
            t = {}
            t['name'] = ob.name
            t['level'] = ob.level
            t['size'] = ob.size
            t['smallestkey'] = ob.smallestkey
            t['largestkey'] = ob.largestkey
            t['smallest_seqno'] = ob.smallest_seqno
            t['largest_seqno'] = ob.largest_seqno

            ret.append(t)

        return ret

    @staticmethod
    def __parse_read_opts(
        verify_checksums=False,
        fill_cache=True,
        prefix_seek=False,
        snapshot=None,
        read_tier="all"):

        # TODO: Is this really effiencet ?
        return locals()

    cdef options.ReadOptions build_read_opts(self, dict py_opts):
        cdef options.ReadOptions opts
        opts.verify_checksums = py_opts['verify_checksums']
        opts.fill_cache = py_opts['fill_cache']
        opts.prefix_seek = py_opts['prefix_seek']
        if py_opts['snapshot'] is not None:
            opts.snapshot = (<Snapshot?>(py_opts['snapshot'])).ptr

        if py_opts['read_tier'] == "all":
            opts.read_tier = options.kReadAllTier
        elif py_opts['read_tier'] == 'cache':
            opts.read_tier = options.kBlockCacheTier
        else:
            raise ValueError("Invalid read_tier")

        return opts

    property options:
        def __get__(self):
            return self.opts

@cython.internal
cdef class Snapshot(object):
    cdef const snapshot.Snapshot* ptr
    cdef DB db

    def __cinit__(self, DB db):
        self.db = db
        self.ptr = db.db.GetSnapshot()

    def __dealloc__(self):
        self.db.db.ReleaseSnapshot(self.ptr)


@cython.internal
cdef class BaseIterator(object):
    cdef iterator.Iterator* ptr
    cdef DB db

    def __cinit__(self, DB db):
        self.db = db
        self.ptr = NULL

    def __dealloc__(self):
        if self.ptr != NULL:
            del self.ptr

    def __iter__(self):
        return self

    def __next__(self):
        if not self.ptr.Valid():
            raise StopIteration()

        cdef object ret = self.get_ob()
        self.ptr.Next()
        return ret

    def __reversed__(self):
        return ReversedIterator(self)

    cpdef seek_to_first(self):
        self.ptr.SeekToFirst()

    cpdef seek_to_last(self):
        self.ptr.SeekToLast()

    cpdef seek(self, key):
        self.ptr.Seek(str_to_slice(key))

    cdef object get_ob(self):
        return None

@cython.internal
cdef class KeysIterator(BaseIterator):
    cdef object get_ob(self):
        return slice_to_str(self.ptr.key())

@cython.internal
cdef class ValuesIterator(BaseIterator):
    cdef object get_ob(self):
        return slice_to_str(self.ptr.value())

@cython.internal
cdef class ItemsIterator(BaseIterator):
    cdef object get_ob(self):
        return (slice_to_str(self.ptr.key()), slice_to_str(self.ptr.value()))

@cython.internal
cdef class ReversedIterator(object):
    cdef BaseIterator it

    def __cinit__(self, BaseIterator it):
        self.it = it

    def seek_to_first(self):
        self.it.seek_to_first()

    def seek_to_last(self):
        self.it.seek_to_last()

    def seek(self, key):
        self.it.seek(key)

    def __iter__(self):
        return self

    def __reversed__(self):
        return self.it

    def __next__(self):
        if not self.it.ptr.Valid():
            raise StopIteration()

        cdef object ret = self.it.get_ob()
        self.it.ptr.Prev()
        return ret
