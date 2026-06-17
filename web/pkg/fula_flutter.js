let wasm_bindgen;
(function() {
    const __exports = {};
    let script_src;
    if (typeof document !== 'undefined' && document.currentScript !== null) {
        script_src = new URL(document.currentScript.src, location.href).toString();
    }
    let wasm = undefined;

    function addToExternrefTable0(obj) {
        const idx = wasm.__externref_table_alloc();
        wasm.__wbindgen_externrefs.set(idx, obj);
        return idx;
    }

    const CLOSURE_DTORS = (typeof FinalizationRegistry === 'undefined')
        ? { register: () => {}, unregister: () => {} }
        : new FinalizationRegistry(state => state.dtor(state.a, state.b));

    function debugString(val) {
        // primitive types
        const type = typeof val;
        if (type == 'number' || type == 'boolean' || val == null) {
            return  `${val}`;
        }
        if (type == 'string') {
            return `"${val}"`;
        }
        if (type == 'symbol') {
            const description = val.description;
            if (description == null) {
                return 'Symbol';
            } else {
                return `Symbol(${description})`;
            }
        }
        if (type == 'function') {
            const name = val.name;
            if (typeof name == 'string' && name.length > 0) {
                return `Function(${name})`;
            } else {
                return 'Function';
            }
        }
        // objects
        if (Array.isArray(val)) {
            const length = val.length;
            let debug = '[';
            if (length > 0) {
                debug += debugString(val[0]);
            }
            for(let i = 1; i < length; i++) {
                debug += ', ' + debugString(val[i]);
            }
            debug += ']';
            return debug;
        }
        // Test for built-in
        const builtInMatches = /\[object ([^\]]+)\]/.exec(toString.call(val));
        let className;
        if (builtInMatches && builtInMatches.length > 1) {
            className = builtInMatches[1];
        } else {
            // Failed to match the standard '[object ClassName]'
            return toString.call(val);
        }
        if (className == 'Object') {
            // we're a user defined class or Object
            // JSON.stringify avoids problems with cycles, and is generally much
            // easier than looping through ownProperties of `val`.
            try {
                return 'Object(' + JSON.stringify(val) + ')';
            } catch (_) {
                return 'Object';
            }
        }
        // errors
        if (val instanceof Error) {
            return `${val.name}: ${val.message}\n${val.stack}`;
        }
        // TODO we could test for more things here, like `Set`s and `Map`s.
        return className;
    }

    function getArrayU8FromWasm0(ptr, len) {
        ptr = ptr >>> 0;
        return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
    }

    let cachedDataViewMemory0 = null;
    function getDataViewMemory0() {
        if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || (cachedDataViewMemory0.buffer.detached === undefined && cachedDataViewMemory0.buffer !== wasm.memory.buffer)) {
            cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
        }
        return cachedDataViewMemory0;
    }

    function getStringFromWasm0(ptr, len) {
        ptr = ptr >>> 0;
        return decodeText(ptr, len);
    }

    let cachedUint8ArrayMemory0 = null;
    function getUint8ArrayMemory0() {
        if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
            cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
        }
        return cachedUint8ArrayMemory0;
    }

    function handleError(f, args) {
        try {
            return f.apply(this, args);
        } catch (e) {
            const idx = addToExternrefTable0(e);
            wasm.__wbindgen_exn_store(idx);
        }
    }

    function isLikeNone(x) {
        return x === undefined || x === null;
    }

    function makeMutClosure(arg0, arg1, dtor, f) {
        const state = { a: arg0, b: arg1, cnt: 1, dtor };
        const real = (...args) => {

            // First up with a closure we increment the internal reference
            // count. This ensures that the Rust closure environment won't
            // be deallocated while we're invoking it.
            state.cnt++;
            const a = state.a;
            state.a = 0;
            try {
                return f(a, state.b, ...args);
            } finally {
                state.a = a;
                real._wbg_cb_unref();
            }
        };
        real._wbg_cb_unref = () => {
            if (--state.cnt === 0) {
                state.dtor(state.a, state.b);
                state.a = 0;
                CLOSURE_DTORS.unregister(state);
            }
        };
        CLOSURE_DTORS.register(real, state, state);
        return real;
    }

    function passArray8ToWasm0(arg, malloc) {
        const ptr = malloc(arg.length * 1, 1) >>> 0;
        getUint8ArrayMemory0().set(arg, ptr / 1);
        WASM_VECTOR_LEN = arg.length;
        return ptr;
    }

    function passArrayJsValueToWasm0(array, malloc) {
        const ptr = malloc(array.length * 4, 4) >>> 0;
        for (let i = 0; i < array.length; i++) {
            const add = addToExternrefTable0(array[i]);
            getDataViewMemory0().setUint32(ptr + 4 * i, add, true);
        }
        WASM_VECTOR_LEN = array.length;
        return ptr;
    }

    function passStringToWasm0(arg, malloc, realloc) {
        if (realloc === undefined) {
            const buf = cachedTextEncoder.encode(arg);
            const ptr = malloc(buf.length, 1) >>> 0;
            getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
            WASM_VECTOR_LEN = buf.length;
            return ptr;
        }

        let len = arg.length;
        let ptr = malloc(len, 1) >>> 0;

        const mem = getUint8ArrayMemory0();

        let offset = 0;

        for (; offset < len; offset++) {
            const code = arg.charCodeAt(offset);
            if (code > 0x7F) break;
            mem[ptr + offset] = code;
        }
        if (offset !== len) {
            if (offset !== 0) {
                arg = arg.slice(offset);
            }
            ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
            const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
            const ret = cachedTextEncoder.encodeInto(arg, view);

            offset += ret.written;
            ptr = realloc(ptr, len, offset, 1) >>> 0;
        }

        WASM_VECTOR_LEN = offset;
        return ptr;
    }

    function takeFromExternrefTable0(idx) {
        const value = wasm.__wbindgen_externrefs.get(idx);
        wasm.__externref_table_dealloc(idx);
        return value;
    }

    let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
    cachedTextDecoder.decode();
    function decodeText(ptr, len) {
        return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
    }

    const cachedTextEncoder = new TextEncoder();

    if (!('encodeInto' in cachedTextEncoder)) {
        cachedTextEncoder.encodeInto = function (arg, view) {
            const buf = cachedTextEncoder.encode(arg);
            view.set(buf);
            return {
                read: arg.length,
                written: buf.length
            };
        }
    }

    let WASM_VECTOR_LEN = 0;

    function wasm_bindgen__convert__closures_____invoke__h89b57d53ed7c2005(arg0, arg1, arg2) {
        wasm.wasm_bindgen__convert__closures_____invoke__h89b57d53ed7c2005(arg0, arg1, arg2);
    }

    function wasm_bindgen__convert__closures_____invoke__h517c9bfd8b0e7441(arg0, arg1) {
        wasm.wasm_bindgen__convert__closures_____invoke__h517c9bfd8b0e7441(arg0, arg1);
    }

    function wasm_bindgen__convert__closures_____invoke__h125d5060f3bccfeb(arg0, arg1) {
        wasm.wasm_bindgen__convert__closures_____invoke__h125d5060f3bccfeb(arg0, arg1);
    }

    function wasm_bindgen__convert__closures_____invoke__h156dc1696d09afb9(arg0, arg1, arg2) {
        wasm.wasm_bindgen__convert__closures_____invoke__h156dc1696d09afb9(arg0, arg1, arg2);
    }

    const __wbindgen_enum_RequestCache = ["default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached"];

    const __wbindgen_enum_RequestCredentials = ["omit", "same-origin", "include"];

    const __wbindgen_enum_RequestMode = ["same-origin", "no-cors", "cors", "navigate"];

    const WorkerPoolFinalization = (typeof FinalizationRegistry === 'undefined')
        ? { register: () => {}, unregister: () => {} }
        : new FinalizationRegistry(ptr => wasm.__wbg_workerpool_free(ptr >>> 0, 1));

    class WorkerPool {
        static __wrap(ptr) {
            ptr = ptr >>> 0;
            const obj = Object.create(WorkerPool.prototype);
            obj.__wbg_ptr = ptr;
            WorkerPoolFinalization.register(obj, obj.__wbg_ptr, obj);
            return obj;
        }
        __destroy_into_raw() {
            const ptr = this.__wbg_ptr;
            this.__wbg_ptr = 0;
            WorkerPoolFinalization.unregister(this);
            return ptr;
        }
        free() {
            const ptr = this.__destroy_into_raw();
            wasm.__wbg_workerpool_free(ptr, 0);
        }
        /**
         * @param {number | null} [initial]
         * @param {string | null} [script_src]
         * @param {string | null} [worker_js_preamble]
         * @returns {WorkerPool}
         */
        static new(initial, script_src, worker_js_preamble) {
            var ptr0 = isLikeNone(script_src) ? 0 : passStringToWasm0(script_src, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            var len0 = WASM_VECTOR_LEN;
            var ptr1 = isLikeNone(worker_js_preamble) ? 0 : passStringToWasm0(worker_js_preamble, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            var len1 = WASM_VECTOR_LEN;
            const ret = wasm.workerpool_new(isLikeNone(initial) ? 0x100000001 : (initial) >>> 0, ptr0, len0, ptr1, len1);
            if (ret[2]) {
                throw takeFromExternrefTable0(ret[1]);
            }
            return WorkerPool.__wrap(ret[0]);
        }
        /**
         * Creates a new `WorkerPool` which immediately creates `initial` workers.
         *
         * The pool created here can be used over a long period of time, and it
         * will be initially primed with `initial` workers. Currently workers are
         * never released or gc'd until the whole pool is destroyed.
         *
         * # Errors
         *
         * Returns any error that may happen while a JS web worker is created and a
         * message is sent to it.
         * @param {number} initial
         * @param {string} script_src
         * @param {string} worker_js_preamble
         */
        constructor(initial, script_src, worker_js_preamble) {
            const ptr0 = passStringToWasm0(script_src, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len0 = WASM_VECTOR_LEN;
            const ptr1 = passStringToWasm0(worker_js_preamble, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            const ret = wasm.workerpool_new_raw(initial, ptr0, len0, ptr1, len1);
            if (ret[2]) {
                throw takeFromExternrefTable0(ret[1]);
            }
            this.__wbg_ptr = ret[0] >>> 0;
            WorkerPoolFinalization.register(this, this.__wbg_ptr, this);
            return this;
        }
    }
    if (Symbol.dispose) WorkerPool.prototype[Symbol.dispose] = WorkerPool.prototype.free;
    __exports.WorkerPool = WorkerPool;

    /**
     * @param {number} call_id
     * @param {any} ptr_
     * @param {number} rust_vec_len_
     * @param {number} data_len_
     */
    function frb_dart_fn_deliver_output(call_id, ptr_, rust_vec_len_, data_len_) {
        wasm.frb_dart_fn_deliver_output(call_id, ptr_, rust_vec_len_, data_len_);
    }
    __exports.frb_dart_fn_deliver_output = frb_dart_fn_deliver_output;

    /**
     * # Safety
     *
     * This should never be called manually.
     * @param {any} handle
     * @param {any} dart_handler_port
     * @returns {number}
     */
    function frb_dart_opaque_dart2rust_encode(handle, dart_handler_port) {
        const ret = wasm.frb_dart_opaque_dart2rust_encode(handle, dart_handler_port);
        return ret >>> 0;
    }
    __exports.frb_dart_opaque_dart2rust_encode = frb_dart_opaque_dart2rust_encode;

    /**
     * @param {number} ptr
     */
    function frb_dart_opaque_drop_thread_box_persistent_handle(ptr) {
        wasm.frb_dart_opaque_drop_thread_box_persistent_handle(ptr);
    }
    __exports.frb_dart_opaque_drop_thread_box_persistent_handle = frb_dart_opaque_drop_thread_box_persistent_handle;

    /**
     * @param {number} ptr
     * @returns {any}
     */
    function frb_dart_opaque_rust2dart_decode(ptr) {
        const ret = wasm.frb_dart_opaque_rust2dart_decode(ptr);
        return ret;
    }
    __exports.frb_dart_opaque_rust2dart_decode = frb_dart_opaque_rust2dart_decode;

    /**
     * @returns {number}
     */
    function frb_get_rust_content_hash() {
        const ret = wasm.frb_get_rust_content_hash();
        return ret;
    }
    __exports.frb_get_rust_content_hash = frb_get_rust_content_hash;

    /**
     * @param {number} func_id
     * @param {any} port_
     * @param {any} ptr_
     * @param {number} rust_vec_len_
     * @param {number} data_len_
     */
    function frb_pde_ffi_dispatcher_primary(func_id, port_, ptr_, rust_vec_len_, data_len_) {
        wasm.frb_pde_ffi_dispatcher_primary(func_id, port_, ptr_, rust_vec_len_, data_len_);
    }
    __exports.frb_pde_ffi_dispatcher_primary = frb_pde_ffi_dispatcher_primary;

    /**
     * @param {number} func_id
     * @param {any} ptr_
     * @param {number} rust_vec_len_
     * @param {number} data_len_
     * @returns {any}
     */
    function frb_pde_ffi_dispatcher_sync(func_id, ptr_, rust_vec_len_, data_len_) {
        const ret = wasm.frb_pde_ffi_dispatcher_sync(func_id, ptr_, rust_vec_len_, data_len_);
        return ret;
    }
    __exports.frb_pde_ffi_dispatcher_sync = frb_pde_ffi_dispatcher_sync;

    /**
     * ## Safety
     * This function reclaims a raw pointer created by [`TransferClosure`], and therefore
     * should **only** be used in conjunction with it.
     * Furthermore, the WASM module in the worker must have been initialized with the shared
     * memory from the host JS scope.
     * @param {number} payload
     * @param {any[]} transfer
     */
    function receive_transfer_closure(payload, transfer) {
        const ptr0 = passArrayJsValueToWasm0(transfer, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.receive_transfer_closure(payload, ptr0, len0);
        if (ret[1]) {
            throw takeFromExternrefTable0(ret[0]);
        }
    }
    __exports.receive_transfer_closure = receive_transfer_closure;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle(ptr) {
        wasm.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle(ptr);
    }
    __exports.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle = rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerCancelHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerEncryptedClientHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFulaClientHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerMultipartHandle;

    /**
     * @param {number} ptr
     */
    function rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle(ptr) {
        wasm.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerAcceptedShareHandle(ptr);
    }
    __exports.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle = rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRotationManagerHandle;

    function wasm_start_callback() {
        wasm.wasm_start_callback();
    }
    __exports.wasm_start_callback = wasm_start_callback;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__chunked__get_chunked(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__chunked__get_chunked(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__chunked__get_chunked = wire__crate__api__chunked__get_chunked;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {any} offset
     * @param {any} length
     */
    function wire__crate__api__chunked__get_range(port_, client, bucket, key, offset, length) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__chunked__get_range(port_, client, ptr0, len0, ptr1, len1, offset, length);
    }
    __exports.wire__crate__api__chunked__get_range = wire__crate__api__chunked__get_range;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     * @param {any} chunk_size
     */
    function wire__crate__api__chunked__put_chunked(port_, client, bucket, key, data, chunk_size) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__chunked__put_chunked(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, chunk_size);
    }
    __exports.wire__crate__api__chunked__put_chunked = wire__crate__api__chunked__put_chunked;

    /**
     * @param {any} port_
     * @param {any} size
     */
    function wire__crate__api__chunked__should_use_chunked(port_, size) {
        wasm.wire__crate__api__chunked__should_use_chunked(port_, size);
    }
    __exports.wire__crate__api__chunked__should_use_chunked = wire__crate__api__chunked__should_use_chunked;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} name
     */
    function wire__crate__api__client__bucket_exists(port_, client, name) {
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__bucket_exists(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__client__bucket_exists = wire__crate__api__client__bucket_exists;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} src_bucket
     * @param {string} src_key
     * @param {string} dst_bucket
     * @param {string} dst_key
     */
    function wire__crate__api__client__copy_object(port_, client, src_bucket, src_key, dst_bucket, dst_key) {
        const ptr0 = passStringToWasm0(src_bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(src_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(dst_bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(dst_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__copy_object(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__client__copy_object = wire__crate__api__client__copy_object;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} name
     */
    function wire__crate__api__client__create_bucket(port_, client, name) {
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__create_bucket(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__client__create_bucket = wire__crate__api__client__create_bucket;

    /**
     * @param {any} port_
     * @param {any} config
     */
    function wire__crate__api__client__create_client(port_, config) {
        wasm.wire__crate__api__client__create_client(port_, config);
    }
    __exports.wire__crate__api__client__create_client = wire__crate__api__client__create_client;

    /**
     * @param {any} port_
     * @param {any} config
     * @param {any} encryption
     */
    function wire__crate__api__client__create_encrypted_client(port_, config, encryption) {
        wasm.wire__crate__api__client__create_encrypted_client(port_, config, encryption);
    }
    __exports.wire__crate__api__client__create_encrypted_client = wire__crate__api__client__create_encrypted_client;

    /**
     * @param {any} port_
     * @param {any} config
     * @param {any} encryption
     * @param {any} pinning
     */
    function wire__crate__api__client__create_encrypted_client_with_pinning(port_, config, encryption, pinning) {
        wasm.wire__crate__api__client__create_encrypted_client_with_pinning(port_, config, encryption, pinning);
    }
    __exports.wire__crate__api__client__create_encrypted_client_with_pinning = wire__crate__api__client__create_encrypted_client_with_pinning;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} name
     */
    function wire__crate__api__client__delete_bucket(port_, client, name) {
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__delete_bucket(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__client__delete_bucket = wire__crate__api__client__delete_bucket;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__delete_object(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__delete_object(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__delete_object = wire__crate__api__client__delete_object;

    /**
     * @param {any} port_
     * @param {string} email
     */
    function wire__crate__api__client__derive_user_key_from_email(port_, email) {
        const ptr0 = passStringToWasm0(email, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__derive_user_key_from_email(port_, ptr0, len0);
    }
    __exports.wire__crate__api__client__derive_user_key_from_email = wire__crate__api__client__derive_user_key_from_email;

    /**
     * @param {any} port_
     * @param {string} jwt_sub
     */
    function wire__crate__api__client__derive_user_key_from_jwt_sub(port_, jwt_sub) {
        const ptr0 = passStringToWasm0(jwt_sub, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__derive_user_key_from_jwt_sub(port_, ptr0, len0);
    }
    __exports.wire__crate__api__client__derive_user_key_from_jwt_sub = wire__crate__api__client__derive_user_key_from_jwt_sub;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__client__get_last_master_health_event(port_, client) {
        wasm.wire__crate__api__client__get_last_master_health_event(port_, client);
    }
    __exports.wire__crate__api__client__get_last_master_health_event = wire__crate__api__client__get_last_master_health_event;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__client__get_last_master_health_event_encrypted(port_, client) {
        wasm.wire__crate__api__client__get_last_master_health_event_encrypted(port_, client);
    }
    __exports.wire__crate__api__client__get_last_master_health_event_encrypted = wire__crate__api__client__get_last_master_health_event_encrypted;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__get_object(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__get_object(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__get_object = wire__crate__api__client__get_object;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__get_object_with_metadata(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__get_object_with_metadata(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__get_object_with_metadata = wire__crate__api__client__get_object_with_metadata;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__get_object_with_offline_fallback(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__get_object_with_offline_fallback(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__get_object_with_offline_fallback = wire__crate__api__client__get_object_with_offline_fallback;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__head_object(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__head_object(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__head_object = wire__crate__api__client__head_object;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__client__list_buckets(port_, client) {
        wasm.wire__crate__api__client__list_buckets(port_, client);
    }
    __exports.wire__crate__api__client__list_buckets = wire__crate__api__client__list_buckets;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {any} options
     */
    function wire__crate__api__client__list_objects(port_, client, bucket, options) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__list_objects(port_, client, ptr0, len0, options);
    }
    __exports.wire__crate__api__client__list_objects = wire__crate__api__client__list_objects;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__client__object_exists(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__object_exists(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__client__object_exists = wire__crate__api__client__object_exists;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__client__poll_master_health_events(port_, client) {
        wasm.wire__crate__api__client__poll_master_health_events(port_, client);
    }
    __exports.wire__crate__api__client__poll_master_health_events = wire__crate__api__client__poll_master_health_events;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__client__poll_master_health_events_encrypted(port_, client) {
        wasm.wire__crate__api__client__poll_master_health_events_encrypted(port_, client);
    }
    __exports.wire__crate__api__client__poll_master_health_events_encrypted = wire__crate__api__client__poll_master_health_events_encrypted;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     */
    function wire__crate__api__client__put_object(port_, client, bucket, key, data) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__put_object(port_, client, ptr0, len0, ptr1, len1, ptr2, len2);
    }
    __exports.wire__crate__api__client__put_object = wire__crate__api__client__put_object;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     * @param {any} metadata
     */
    function wire__crate__api__client__put_object_with_metadata(port_, client, bucket, key, data, metadata) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__client__put_object_with_metadata(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, metadata);
    }
    __exports.wire__crate__api__client__put_object_with_metadata = wire__crate__api__client__put_object_with_metadata;

    /**
     * @param {any} port_
     * @param {string} context
     * @param {Uint8Array} input
     */
    function wire__crate__api__encrypted__blake3_derive_key(port_, context, input) {
        const ptr0 = passStringToWasm0(context, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(input, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__blake3_derive_key(port_, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__blake3_derive_key = wire__crate__api__encrypted__blake3_derive_key;

    /**
     * @param {any} port_
     * @param {string} provider
     * @param {string} oauth_sub
     * @param {string} seed
     */
    function wire__crate__api__encrypted__compute_effective_user_id_mode_b(port_, provider, oauth_sub, seed) {
        const ptr0 = passStringToWasm0(provider, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(oauth_sub, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(seed, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__compute_effective_user_id_mode_b(port_, ptr0, len0, ptr1, len1, ptr2, len2);
    }
    __exports.wire__crate__api__encrypted__compute_effective_user_id_mode_b = wire__crate__api__encrypted__compute_effective_user_id_mode_b;

    /**
     * @param {any} port_
     * @param {string} seed
     */
    function wire__crate__api__encrypted__compute_effective_user_id_mode_c(port_, seed) {
        const ptr0 = passStringToWasm0(seed, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__compute_effective_user_id_mode_c(port_, ptr0, len0);
    }
    __exports.wire__crate__api__encrypted__compute_effective_user_id_mode_c = wire__crate__api__encrypted__compute_effective_user_id_mode_c;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__encrypted__delete_by_storage_key(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__delete_by_storage_key(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__delete_by_storage_key = wire__crate__api__encrypted__delete_by_storage_key;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__encrypted__delete_encrypted(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__delete_encrypted(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__delete_encrypted = wire__crate__api__encrypted__delete_encrypted;

    /**
     * @param {any} port_
     * @param {string} context
     * @param {Uint8Array} input
     */
    function wire__crate__api__encrypted__derive_key(port_, context, input) {
        const ptr0 = passStringToWasm0(context, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(input, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__derive_key(port_, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__derive_key = wire__crate__api__encrypted__derive_key;

    /**
     * @param {any} port_
     * @param {string} context
     * @param {Uint8Array} input
     * @param {Uint8Array} salt
     */
    function wire__crate__api__encrypted__derive_key_with_salt(port_, context, input, salt) {
        const ptr0 = passStringToWasm0(context, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(input, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(salt, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__derive_key_with_salt(port_, ptr0, len0, ptr1, len1, ptr2, len2);
    }
    __exports.wire__crate__api__encrypted__derive_key_with_salt = wire__crate__api__encrypted__derive_key_with_salt;

    /**
     * @param {any} port_
     * @param {Uint8Array} secret_key_bytes
     */
    function wire__crate__api__encrypted__derive_public_key_from_secret(port_, secret_key_bytes) {
        const ptr0 = passArray8ToWasm0(secret_key_bytes, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__derive_public_key_from_secret(port_, ptr0, len0);
    }
    __exports.wire__crate__api__encrypted__derive_public_key_from_secret = wire__crate__api__encrypted__derive_public_key_from_secret;

    /**
     * @param {any} port_
     * @param {string} seed
     */
    function wire__crate__api__encrypted__derive_signing_seed(port_, seed) {
        const ptr0 = passStringToWasm0(seed, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__derive_signing_seed(port_, ptr0, len0);
    }
    __exports.wire__crate__api__encrypted__derive_signing_seed = wire__crate__api__encrypted__derive_signing_seed;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} name
     */
    function wire__crate__api__encrypted__enc_create_bucket(port_, client, name) {
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__enc_create_bucket(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__encrypted__enc_create_bucket = wire__crate__api__encrypted__enc_create_bucket;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} name
     */
    function wire__crate__api__encrypted__enc_delete_bucket(port_, client, name) {
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__enc_delete_bucket(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__encrypted__enc_delete_bucket = wire__crate__api__encrypted__enc_delete_bucket;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__encrypted__enc_list_buckets(port_, client) {
        wasm.wire__crate__api__encrypted__enc_list_buckets(port_, client);
    }
    __exports.wire__crate__api__encrypted__enc_list_buckets = wire__crate__api__encrypted__enc_list_buckets;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__encrypted__export_secret_key(port_, client) {
        wasm.wire__crate__api__encrypted__export_secret_key(port_, client);
    }
    __exports.wire__crate__api__encrypted__export_secret_key = wire__crate__api__encrypted__export_secret_key;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__encrypted__get_decrypted(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__get_decrypted(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__get_decrypted = wire__crate__api__encrypted__get_decrypted;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__encrypted__get_decrypted_buffered(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__get_decrypted_buffered(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__get_decrypted_buffered = wire__crate__api__encrypted__get_decrypted_buffered;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__encrypted__get_decrypted_buffered_by_storage_key(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__get_decrypted_buffered_by_storage_key(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__get_decrypted_buffered_by_storage_key = wire__crate__api__encrypted__get_decrypted_buffered_by_storage_key;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__encrypted__get_decrypted_by_storage_key(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__get_decrypted_by_storage_key(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__get_decrypted_by_storage_key = wire__crate__api__encrypted__get_decrypted_by_storage_key;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__encrypted__get_public_key(port_, client) {
        wasm.wire__crate__api__encrypted__get_public_key(port_, client);
    }
    __exports.wire__crate__api__encrypted__get_public_key = wire__crate__api__encrypted__get_public_key;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__encrypted__get_with_private_metadata(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__get_with_private_metadata(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__get_with_private_metadata = wire__crate__api__encrypted__get_with_private_metadata;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__encrypted__head_decrypted(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__head_decrypted(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__head_decrypted = wire__crate__api__encrypted__head_decrypted;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__encrypted__is_flat_namespace(port_, client) {
        wasm.wire__crate__api__encrypted__is_flat_namespace(port_, client);
    }
    __exports.wire__crate__api__encrypted__is_flat_namespace = wire__crate__api__encrypted__is_flat_namespace;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {any} options
     */
    function wire__crate__api__encrypted__list_decrypted(port_, client, bucket, options) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__list_decrypted(port_, client, ptr0, len0, options);
    }
    __exports.wire__crate__api__encrypted__list_decrypted = wire__crate__api__encrypted__list_decrypted;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string | null} [prefix]
     */
    function wire__crate__api__encrypted__list_directory(port_, client, bucket, prefix) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        var ptr1 = isLikeNone(prefix) ? 0 : passStringToWasm0(prefix, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__list_directory(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__encrypted__list_directory = wire__crate__api__encrypted__list_directory;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     */
    function wire__crate__api__encrypted__put_encrypted(port_, client, bucket, key, data) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__put_encrypted(port_, client, ptr0, len0, ptr1, len1, ptr2, len2);
    }
    __exports.wire__crate__api__encrypted__put_encrypted = wire__crate__api__encrypted__put_encrypted;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     * @param {string} content_type
     */
    function wire__crate__api__encrypted__put_encrypted_with_type(port_, client, bucket, key, data, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__encrypted__put_encrypted_with_type(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__encrypted__put_encrypted_with_type = wire__crate__api__encrypted__put_encrypted_with_type;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_error_code(port_, that) {
        wasm.wire__crate__api__error__fula_error_error_code(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_error_code = wire__crate__api__error__fula_error_error_code;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_access_denied(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_access_denied(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_access_denied = wire__crate__api__error__fula_error_is_access_denied;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_cache_error(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_cache_error(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_cache_error = wire__crate__api__error__fula_error_is_cache_error;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_encryption_error(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_encryption_error(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_encryption_error = wire__crate__api__error__fula_error_is_encryption_error;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_network_error(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_network_error(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_network_error = wire__crate__api__error__fula_error_is_network_error;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_not_found(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_not_found(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_not_found = wire__crate__api__error__fula_error_is_not_found;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__error__fula_error_is_users_index_error(port_, that) {
        wasm.wire__crate__api__error__fula_error_is_users_index_error(port_, that);
    }
    __exports.wire__crate__api__error__fula_error_is_users_index_error = wire__crate__api__error__fula_error_is_users_index_error;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} manifest_path
     */
    function wire__crate__api__forest__abort_resumable_upload(port_, client, manifest_path) {
        const ptr0 = passStringToWasm0(manifest_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__abort_resumable_upload(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__abort_resumable_upload = wire__crate__api__forest__abort_resumable_upload;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__forest__cancel_handle_is_cancelled(port_, handle) {
        wasm.wire__crate__api__forest__cancel_handle_is_cancelled(port_, handle);
    }
    __exports.wire__crate__api__forest__cancel_handle_is_cancelled = wire__crate__api__forest__cancel_handle_is_cancelled;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__forest__cancel_handle_trigger(port_, handle) {
        wasm.wire__crate__api__forest__cancel_handle_trigger(port_, handle);
    }
    __exports.wire__crate__api__forest__cancel_handle_trigger = wire__crate__api__forest__cancel_handle_trigger;

    /**
     * @param {any} port_
     */
    function wire__crate__api__forest__create_cancel_handle(port_) {
        wasm.wire__crate__api__forest__create_cancel_handle(port_);
    }
    __exports.wire__crate__api__forest__create_cancel_handle = wire__crate__api__forest__create_cancel_handle;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     */
    function wire__crate__api__forest__delete_flat(port_, client, bucket, path) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__delete_flat(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__forest__delete_flat = wire__crate__api__forest__delete_flat;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__flush_forest(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__flush_forest(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__flush_forest = wire__crate__api__forest__flush_forest;

    /**
     * @param {any} port_
     * @param {string} file_path
     */
    function wire__crate__api__forest__get_file_size(port_, file_path) {
        const ptr0 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__get_file_size(port_, ptr0, len0);
    }
    __exports.wire__crate__api__forest__get_file_size = wire__crate__api__forest__get_file_size;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     */
    function wire__crate__api__forest__get_flat(port_, client, bucket, path) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__get_flat(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__forest__get_flat = wire__crate__api__forest__get_flat;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} prefix
     */
    function wire__crate__api__forest__get_forest_subtree(port_, client, bucket, prefix) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(prefix, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__get_forest_subtree(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__forest__get_forest_subtree = wire__crate__api__forest__get_forest_subtree;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__has_pending_changes(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__has_pending_changes(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__has_pending_changes = wire__crate__api__forest__has_pending_changes;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__forest__invalidate_all_forest_caches(port_, client) {
        wasm.wire__crate__api__forest__invalidate_all_forest_caches(port_, client);
    }
    __exports.wire__crate__api__forest__invalidate_all_forest_caches = wire__crate__api__forest__invalidate_all_forest_caches;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__invalidate_forest_cache(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__invalidate_forest_cache(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__invalidate_forest_cache = wire__crate__api__forest__invalidate_forest_cache;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__list_from_forest(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__list_from_forest(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__list_from_forest = wire__crate__api__forest__list_from_forest;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__load_forest(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__load_forest(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__load_forest = wire__crate__api__forest__load_forest;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {Uint8Array} data
     * @param {string | null} [content_type]
     */
    function wire__crate__api__forest__put_flat(port_, client, bucket, path, data, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        var ptr3 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__forest__put_flat = wire__crate__api__forest__put_flat;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {Uint8Array} data
     * @param {string | null} [content_type]
     */
    function wire__crate__api__forest__put_flat_deferred(port_, client, bucket, path, data, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        var ptr3 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat_deferred(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__forest__put_flat_deferred = wire__crate__api__forest__put_flat_deferred;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {string} file_path
     * @param {string | null} [content_type]
     */
    function wire__crate__api__forest__put_flat_from_path(port_, client, bucket, path, file_path, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        var ptr3 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat_from_path(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__forest__put_flat_from_path = wire__crate__api__forest__put_flat_from_path;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {string} file_path
     * @param {string | null} [content_type]
     */
    function wire__crate__api__forest__put_flat_from_path_deferred(port_, client, bucket, path, file_path, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        var ptr3 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat_from_path_deferred(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__forest__put_flat_from_path_deferred = wire__crate__api__forest__put_flat_from_path_deferred;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {string} file_path
     * @param {string} manifest_path
     * @param {string | null} [content_type]
     */
    function wire__crate__api__forest__put_flat_resumable_from_path(port_, client, bucket, path, file_path, manifest_path, content_type) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(manifest_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        var ptr4 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len4 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat_resumable_from_path(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, ptr4, len4);
    }
    __exports.wire__crate__api__forest__put_flat_resumable_from_path = wire__crate__api__forest__put_flat_resumable_from_path;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} path
     * @param {string} file_path
     * @param {string} manifest_path
     * @param {string | null | undefined} content_type
     * @param {any} cancel
     */
    function wire__crate__api__forest__put_flat_resumable_from_path_cancellable(port_, client, bucket, path, file_path, manifest_path, content_type, cancel) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(manifest_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        var ptr4 = isLikeNone(content_type) ? 0 : passStringToWasm0(content_type, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len4 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__put_flat_resumable_from_path_cancellable(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, ptr4, len4, cancel);
    }
    __exports.wire__crate__api__forest__put_flat_resumable_from_path_cancellable = wire__crate__api__forest__put_flat_resumable_from_path_cancellable;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} manifest_path
     * @param {string} file_path
     */
    function wire__crate__api__forest__resume_flat_upload_from_path(port_, client, manifest_path, file_path) {
        const ptr0 = passStringToWasm0(manifest_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__resume_flat_upload_from_path(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__forest__resume_flat_upload_from_path = wire__crate__api__forest__resume_flat_upload_from_path;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} manifest_path
     * @param {string} file_path
     * @param {any} cancel
     */
    function wire__crate__api__forest__resume_flat_upload_from_path_cancellable(port_, client, manifest_path, file_path, cancel) {
        const ptr0 = passStringToWasm0(manifest_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(file_path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__resume_flat_upload_from_path_cancellable(port_, client, ptr0, len0, ptr1, len1, cancel);
    }
    __exports.wire__crate__api__forest__resume_flat_upload_from_path_cancellable = wire__crate__api__forest__resume_flat_upload_from_path_cancellable;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     */
    function wire__crate__api__forest__save_forest(port_, client, bucket) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__forest__save_forest(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__forest__save_forest = wire__crate__api__forest__save_forest;

    /**
     * @param {any} port_
     */
    function wire__crate__api__metrics__flush_backoff_count(port_) {
        wasm.wire__crate__api__metrics__flush_backoff_count(port_);
    }
    __exports.wire__crate__api__metrics__flush_backoff_count = wire__crate__api__metrics__flush_backoff_count;

    /**
     * @param {any} port_
     */
    function wire__crate__api__metrics__wal_append_failure_count(port_) {
        wasm.wire__crate__api__metrics__wal_append_failure_count(port_);
    }
    __exports.wire__crate__api__metrics__wal_append_failure_count = wire__crate__api__metrics__wal_append_failure_count;

    /**
     * @param {any} port_
     */
    function wire__crate__api__metrics__wal_truncated_groups_count(port_) {
        wasm.wire__crate__api__metrics__wal_truncated_groups_count(port_);
    }
    __exports.wire__crate__api__metrics__wal_truncated_groups_count = wire__crate__api__metrics__wal_truncated_groups_count;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__multipart__abort_multipart(port_, handle) {
        wasm.wire__crate__api__multipart__abort_multipart(port_, handle);
    }
    __exports.wire__crate__api__multipart__abort_multipart = wire__crate__api__multipart__abort_multipart;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__multipart__complete_multipart(port_, handle) {
        wasm.wire__crate__api__multipart__complete_multipart(port_, handle);
    }
    __exports.wire__crate__api__multipart__complete_multipart = wire__crate__api__multipart__complete_multipart;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__multipart__detach_multipart(port_, handle) {
        wasm.wire__crate__api__multipart__detach_multipart(port_, handle);
    }
    __exports.wire__crate__api__multipart__detach_multipart = wire__crate__api__multipart__detach_multipart;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__multipart__get_completed_parts(port_, handle) {
        wasm.wire__crate__api__multipart__get_completed_parts(port_, handle);
    }
    __exports.wire__crate__api__multipart__get_completed_parts = wire__crate__api__multipart__get_completed_parts;

    /**
     * @param {any} port_
     * @param {any} handle
     */
    function wire__crate__api__multipart__get_upload_id(port_, handle) {
        wasm.wire__crate__api__multipart__get_upload_id(port_, handle);
    }
    __exports.wire__crate__api__multipart__get_upload_id = wire__crate__api__multipart__get_upload_id;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     */
    function wire__crate__api__multipart__start_multipart(port_, client, bucket, key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__multipart__start_multipart(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__multipart__start_multipart = wire__crate__api__multipart__start_multipart;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {number} max_concurrency
     */
    function wire__crate__api__multipart__start_multipart_with_concurrency(port_, client, bucket, key, max_concurrency) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__multipart__start_multipart_with_concurrency(port_, client, ptr0, len0, ptr1, len1, max_concurrency);
    }
    __exports.wire__crate__api__multipart__start_multipart_with_concurrency = wire__crate__api__multipart__start_multipart_with_concurrency;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} key
     * @param {Uint8Array} data
     * @param {any} chunk_size
     */
    function wire__crate__api__multipart__upload_large_file_simple(port_, client, bucket, key, data, chunk_size) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__multipart__upload_large_file_simple(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, chunk_size);
    }
    __exports.wire__crate__api__multipart__upload_large_file_simple = wire__crate__api__multipart__upload_large_file_simple;

    /**
     * @param {any} port_
     * @param {any} handle
     * @param {number} part_number
     * @param {Uint8Array} data
     */
    function wire__crate__api__multipart__upload_part(port_, handle, part_number, data) {
        const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__multipart__upload_part(port_, handle, part_number, ptr0, len0);
    }
    __exports.wire__crate__api__multipart__upload_part = wire__crate__api__multipart__upload_part;

    /**
     * @param {any} port_
     * @param {any} client
     */
    function wire__crate__api__rotation__create_rotation_manager(port_, client) {
        wasm.wire__crate__api__rotation__create_rotation_manager(port_, client);
    }
    __exports.wire__crate__api__rotation__create_rotation_manager = wire__crate__api__rotation__create_rotation_manager;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     */
    function wire__crate__api__rotation__get_kek_version(port_, client, bucket, storage_key) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__rotation__get_kek_version(port_, client, ptr0, len0, ptr1, len1);
    }
    __exports.wire__crate__api__rotation__get_kek_version = wire__crate__api__rotation__get_kek_version;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     * @param {any} manager
     */
    function wire__crate__api__rotation__rewrap_object(port_, client, bucket, storage_key, manager) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__rotation__rewrap_object(port_, client, ptr0, len0, ptr1, len1, manager);
    }
    __exports.wire__crate__api__rotation__rewrap_object = wire__crate__api__rotation__rewrap_object;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {any} manager
     */
    function wire__crate__api__rotation__rotate_bucket(port_, client, bucket, manager) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__rotation__rotate_bucket(port_, client, ptr0, len0, manager);
    }
    __exports.wire__crate__api__rotation__rotate_bucket = wire__crate__api__rotation__rotate_bucket;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} token_json
     */
    function wire__crate__api__sharing__accept_share(port_, client, token_json) {
        const ptr0 = passStringToWasm0(token_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__sharing__accept_share(port_, client, ptr0, len0);
    }
    __exports.wire__crate__api__sharing__accept_share = wire__crate__api__sharing__accept_share;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     * @param {Uint8Array} recipient_public_key
     * @param {any} expires_at
     */
    function wire__crate__api__sharing__create_share_token(port_, client, bucket, storage_key, recipient_public_key, expires_at) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(recipient_public_key, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__sharing__create_share_token(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, expires_at);
    }
    __exports.wire__crate__api__sharing__create_share_token = wire__crate__api__sharing__create_share_token;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     * @param {Uint8Array} recipient_public_key
     * @param {number} mode
     * @param {any} expires_at
     */
    function wire__crate__api__sharing__create_share_token_with_mode(port_, client, bucket, storage_key, recipient_public_key, mode, expires_at) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(recipient_public_key, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__sharing__create_share_token_with_mode(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, mode, expires_at);
    }
    __exports.wire__crate__api__sharing__create_share_token_with_mode = wire__crate__api__sharing__create_share_token_with_mode;

    /**
     * @param {any} port_
     * @param {any} share
     */
    function wire__crate__api__sharing__get_share_permissions(port_, share) {
        wasm.wire__crate__api__sharing__get_share_permissions(port_, share);
    }
    __exports.wire__crate__api__sharing__get_share_permissions = wire__crate__api__sharing__get_share_permissions;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     * @param {string} original_key
     * @param {any} share
     */
    function wire__crate__api__sharing__get_with_share(port_, client, bucket, storage_key, original_key, share) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(original_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__sharing__get_with_share(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, share);
    }
    __exports.wire__crate__api__sharing__get_with_share = wire__crate__api__sharing__get_with_share;

    /**
     * @param {any} port_
     * @param {any} client
     * @param {string} bucket
     * @param {string} storage_key
     * @param {string} original_key
     * @param {string} token_json
     */
    function wire__crate__api__sharing__get_with_token(port_, client, bucket, storage_key, original_key, token_json) {
        const ptr0 = passStringToWasm0(bucket, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(storage_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(original_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(token_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        wasm.wire__crate__api__sharing__get_with_token(port_, client, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    }
    __exports.wire__crate__api__sharing__get_with_token = wire__crate__api__sharing__get_with_token;

    /**
     * @param {any} port_
     * @param {any} share
     */
    function wire__crate__api__sharing__is_share_expired(port_, share) {
        wasm.wire__crate__api__sharing__is_share_expired(port_, share);
    }
    __exports.wire__crate__api__sharing__is_share_expired = wire__crate__api__sharing__is_share_expired;

    /**
     * @param {any} port_
     */
    function wire__crate__api__types__encryption_config_default(port_) {
        wasm.wire__crate__api__types__encryption_config_default(port_);
    }
    __exports.wire__crate__api__types__encryption_config_default = wire__crate__api__types__encryption_config_default;

    /**
     * @param {any} port_
     */
    function wire__crate__api__types__fula_config_default(port_) {
        wasm.wire__crate__api__types__fula_config_default(port_);
    }
    __exports.wire__crate__api__types__fula_config_default = wire__crate__api__types__fula_config_default;

    /**
     * @param {any} port_
     */
    function wire__crate__api__types__list_options_default(port_) {
        wasm.wire__crate__api__types__list_options_default(port_);
    }
    __exports.wire__crate__api__types__list_options_default = wire__crate__api__types__list_options_default;

    /**
     * @param {any} port_
     */
    function wire__crate__api__types__obfuscation_mode_default(port_) {
        wasm.wire__crate__api__types__obfuscation_mode_default(port_);
    }
    __exports.wire__crate__api__types__obfuscation_mode_default = wire__crate__api__types__obfuscation_mode_default;

    /**
     * @param {any} port_
     */
    function wire__crate__api__types__object_metadata_default(port_) {
        wasm.wire__crate__api__types__object_metadata_default(port_);
    }
    __exports.wire__crate__api__types__object_metadata_default = wire__crate__api__types__object_metadata_default;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__types__rotation_report_is_success(port_, that) {
        wasm.wire__crate__api__types__rotation_report_is_success(port_, that);
    }
    __exports.wire__crate__api__types__rotation_report_is_success = wire__crate__api__types__rotation_report_is_success;

    /**
     * @param {any} port_
     * @param {any} that
     */
    function wire__crate__api__types__rotation_report_success_rate(port_, that) {
        wasm.wire__crate__api__types__rotation_report_success_rate(port_, that);
    }
    __exports.wire__crate__api__types__rotation_report_success_rate = wire__crate__api__types__rotation_report_success_rate;

    /**
     * @param {any} port_
     * @param {any} bytes_uploaded
     * @param {any} total_bytes
     * @param {number} current_part
     * @param {number} total_parts
     */
    function wire__crate__api__types__upload_progress_new(port_, bytes_uploaded, total_bytes, current_part, total_parts) {
        wasm.wire__crate__api__types__upload_progress_new(port_, bytes_uploaded, total_bytes, current_part, total_parts);
    }
    __exports.wire__crate__api__types__upload_progress_new = wire__crate__api__types__upload_progress_new;

    const EXPECTED_RESPONSE_TYPES = new Set(['basic', 'cors', 'default']);

    async function __wbg_load(module, imports) {
        if (typeof Response === 'function' && module instanceof Response) {
            if (typeof WebAssembly.instantiateStreaming === 'function') {
                try {
                    return await WebAssembly.instantiateStreaming(module, imports);
                } catch (e) {
                    const validResponse = module.ok && EXPECTED_RESPONSE_TYPES.has(module.type);

                    if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                        console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                    } else {
                        throw e;
                    }
                }
            }

            const bytes = await module.arrayBuffer();
            return await WebAssembly.instantiate(bytes, imports);
        } else {
            const instance = await WebAssembly.instantiate(module, imports);

            if (instance instanceof WebAssembly.Instance) {
                return { instance, module };
            } else {
                return instance;
            }
        }
    }

    function __wbg_get_imports() {
        const imports = {};
        imports.wbg = {};
        imports.wbg.__wbg_Number_2d1dcfcf4ec51736 = function(arg0) {
            const ret = Number(arg0);
            return ret;
        };
        imports.wbg.__wbg___wbindgen_bigint_get_as_i64_6e32f5e6aff02e1d = function(arg0, arg1) {
            const v = arg1;
            const ret = typeof(v) === 'bigint' ? v : undefined;
            getDataViewMemory0().setBigInt64(arg0 + 8 * 1, isLikeNone(ret) ? BigInt(0) : ret, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, !isLikeNone(ret), true);
        };
        imports.wbg.__wbg___wbindgen_debug_string_adfb662ae34724b6 = function(arg0, arg1) {
            const ret = debugString(arg1);
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg___wbindgen_is_falsy_7b9692021c137978 = function(arg0) {
            const ret = !arg0;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_is_function_8d400b8b1af978cd = function(arg0) {
            const ret = typeof(arg0) === 'function';
            return ret;
        };
        imports.wbg.__wbg___wbindgen_is_null_dfda7d66506c95b5 = function(arg0) {
            const ret = arg0 === null;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_is_object_ce774f3490692386 = function(arg0) {
            const val = arg0;
            const ret = typeof(val) === 'object' && val !== null;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_is_string_704ef9c8fc131030 = function(arg0) {
            const ret = typeof(arg0) === 'string';
            return ret;
        };
        imports.wbg.__wbg___wbindgen_is_undefined_f6b95eab589e0269 = function(arg0) {
            const ret = arg0 === undefined;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_jsval_eq_b6101cc9cef1fe36 = function(arg0, arg1) {
            const ret = arg0 === arg1;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_memory_a342e963fbcabd68 = function() {
            const ret = wasm.memory;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_module_967adef62ea6cbf8 = function() {
            const ret = __wbg_init.__wbindgen_wasm_module;
            return ret;
        };
        imports.wbg.__wbg___wbindgen_number_get_9619185a74197f95 = function(arg0, arg1) {
            const obj = arg1;
            const ret = typeof(obj) === 'number' ? obj : undefined;
            getDataViewMemory0().setFloat64(arg0 + 8 * 1, isLikeNone(ret) ? 0 : ret, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, !isLikeNone(ret), true);
        };
        imports.wbg.__wbg___wbindgen_string_get_a2a31e16edf96e42 = function(arg0, arg1) {
            const obj = arg1;
            const ret = typeof(obj) === 'string' ? obj : undefined;
            var ptr1 = isLikeNone(ret) ? 0 : passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg___wbindgen_throw_dd24417ed36fc46e = function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        };
        imports.wbg.__wbg__wbg_cb_unref_87dfb5aaa0cbcea7 = function(arg0) {
            arg0._wbg_cb_unref();
        };
        imports.wbg.__wbg_abort_07646c894ebbf2bd = function(arg0) {
            arg0.abort();
        };
        imports.wbg.__wbg_abort_399ecbcfd6ef3c8e = function(arg0, arg1) {
            arg0.abort(arg1);
        };
        imports.wbg.__wbg_append_c5cbdf46455cc776 = function() { return handleError(function (arg0, arg1, arg2, arg3, arg4) {
            arg0.append(getStringFromWasm0(arg1, arg2), getStringFromWasm0(arg3, arg4));
        }, arguments) };
        imports.wbg.__wbg_arrayBuffer_c04af4fce566092d = function() { return handleError(function (arg0) {
            const ret = arg0.arrayBuffer();
            return ret;
        }, arguments) };
        imports.wbg.__wbg_call_3020136f7a2d6e44 = function() { return handleError(function (arg0, arg1, arg2) {
            const ret = arg0.call(arg1, arg2);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_call_abb4ff46ce38be40 = function() { return handleError(function (arg0, arg1) {
            const ret = arg0.call(arg1);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_clearTimeout_5a54f8841c30079a = function(arg0) {
            const ret = clearTimeout(arg0);
            return ret;
        };
        imports.wbg.__wbg_clearTimeout_7a42b49784aea641 = function(arg0) {
            const ret = clearTimeout(arg0);
            return ret;
        };
        imports.wbg.__wbg_createObjectURL_7d9f7f8f41373850 = function() { return handleError(function (arg0, arg1) {
            const ret = URL.createObjectURL(arg1);
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        }, arguments) };
        imports.wbg.__wbg_crypto_574e78ad8b13b65f = function(arg0) {
            const ret = arg0.crypto;
            return ret;
        };
        imports.wbg.__wbg_data_8bf4ae669a78a688 = function(arg0) {
            const ret = arg0.data;
            return ret;
        };
        imports.wbg.__wbg_done_62ea16af4ce34b24 = function(arg0) {
            const ret = arg0.done;
            return ret;
        };
        imports.wbg.__wbg_error_076d4beefd7cfd14 = function(arg0, arg1) {
            console.error(getStringFromWasm0(arg0, arg1));
        };
        imports.wbg.__wbg_error_7534b8e9a36f1ab4 = function(arg0, arg1) {
            let deferred0_0;
            let deferred0_1;
            try {
                deferred0_0 = arg0;
                deferred0_1 = arg1;
                console.error(getStringFromWasm0(arg0, arg1));
            } finally {
                wasm.__wbindgen_free(deferred0_0, deferred0_1, 1);
            }
        };
        imports.wbg.__wbg_eval_aa18aa048f37d16d = function() { return handleError(function (arg0, arg1) {
            const ret = eval(getStringFromWasm0(arg0, arg1));
            return ret;
        }, arguments) };
        imports.wbg.__wbg_fetch_74a3e84ebd2c9a0e = function(arg0) {
            const ret = fetch(arg0);
            return ret;
        };
        imports.wbg.__wbg_fetch_90447c28cc0b095e = function(arg0, arg1) {
            const ret = arg0.fetch(arg1);
            return ret;
        };
        imports.wbg.__wbg_getRandomValues_b8f5dbd5f3995a9e = function() { return handleError(function (arg0, arg1) {
            arg0.getRandomValues(arg1);
        }, arguments) };
        imports.wbg.__wbg_getTime_ad1e9878a735af08 = function(arg0) {
            const ret = arg0.getTime();
            return ret;
        };
        imports.wbg.__wbg_get_6b7bd52aca3f9671 = function(arg0, arg1) {
            const ret = arg0[arg1 >>> 0];
            return ret;
        };
        imports.wbg.__wbg_get_af9dab7e9603ea93 = function() { return handleError(function (arg0, arg1) {
            const ret = Reflect.get(arg0, arg1);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_has_0e670569d65d3a45 = function() { return handleError(function (arg0, arg1) {
            const ret = Reflect.has(arg0, arg1);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_headers_654c30e1bcccc552 = function(arg0) {
            const ret = arg0.headers;
            return ret;
        };
        imports.wbg.__wbg_instanceof_BroadcastChannel_20b7abd1aa1b1ce9 = function(arg0) {
            let result;
            try {
                result = arg0 instanceof BroadcastChannel;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        };
        imports.wbg.__wbg_instanceof_ErrorEvent_395a0232f8587b08 = function(arg0) {
            let result;
            try {
                result = arg0 instanceof ErrorEvent;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        };
        imports.wbg.__wbg_instanceof_MessageEvent_41de26e7cb8539ce = function(arg0) {
            let result;
            try {
                result = arg0 instanceof MessageEvent;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        };
        imports.wbg.__wbg_instanceof_MessagePort_c6d647a8cffdd1a6 = function(arg0) {
            let result;
            try {
                result = arg0 instanceof MessagePort;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        };
        imports.wbg.__wbg_instanceof_Response_cd74d1c2ac92cb0b = function(arg0) {
            let result;
            try {
                result = arg0 instanceof Response;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        };
        imports.wbg.__wbg_isArray_51fd9e6422c0a395 = function(arg0) {
            const ret = Array.isArray(arg0);
            return ret;
        };
        imports.wbg.__wbg_iterator_27b7c8b35ab3e86b = function() {
            const ret = Symbol.iterator;
            return ret;
        };
        imports.wbg.__wbg_length_22ac23eaec9d8053 = function(arg0) {
            const ret = arg0.length;
            return ret;
        };
        imports.wbg.__wbg_length_d45040a40c570362 = function(arg0) {
            const ret = arg0.length;
            return ret;
        };
        imports.wbg.__wbg_message_0ff7f09380783844 = function(arg0, arg1) {
            const ret = arg1.message;
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg_msCrypto_a61aeb35a24c1329 = function(arg0) {
            const ret = arg0.msCrypto;
            return ret;
        };
        imports.wbg.__wbg_name_5ac7feee5b67b1f9 = function(arg0, arg1) {
            const ret = arg1.name;
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg_new_0_23cedd11d9b40c9d = function() {
            const ret = new Date();
            return ret;
        };
        imports.wbg.__wbg_new_1ba21ce319a06297 = function() {
            const ret = new Object();
            return ret;
        };
        imports.wbg.__wbg_new_25f239778d6112b9 = function() {
            const ret = new Array();
            return ret;
        };
        imports.wbg.__wbg_new_3c79b3bb1b32b7d3 = function() { return handleError(function () {
            const ret = new Headers();
            return ret;
        }, arguments) };
        imports.wbg.__wbg_new_53cb1e86c1ef5d2a = function() { return handleError(function (arg0, arg1) {
            const ret = new Worker(getStringFromWasm0(arg0, arg1));
            return ret;
        }, arguments) };
        imports.wbg.__wbg_new_6421f6084cc5bc5a = function(arg0) {
            const ret = new Uint8Array(arg0);
            return ret;
        };
        imports.wbg.__wbg_new_881a222c65f168fc = function() { return handleError(function () {
            const ret = new AbortController();
            return ret;
        }, arguments) };
        imports.wbg.__wbg_new_8a6f238a6ece86ea = function() {
            const ret = new Error();
            return ret;
        };
        imports.wbg.__wbg_new_b3dd747604c3c93e = function() { return handleError(function (arg0, arg1) {
            const ret = new BroadcastChannel(getStringFromWasm0(arg0, arg1));
            return ret;
        }, arguments) };
        imports.wbg.__wbg_new_from_slice_f9c22b9153b26992 = function(arg0, arg1) {
            const ret = new Uint8Array(getArrayU8FromWasm0(arg0, arg1));
            return ret;
        };
        imports.wbg.__wbg_new_no_args_cb138f77cf6151ee = function(arg0, arg1) {
            const ret = new Function(getStringFromWasm0(arg0, arg1));
            return ret;
        };
        imports.wbg.__wbg_new_with_blob_sequence_and_options_effa70dbbcafea53 = function() { return handleError(function (arg0, arg1) {
            const ret = new Blob(arg0, arg1);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_new_with_length_aa5eaf41d35235e5 = function(arg0) {
            const ret = new Uint8Array(arg0 >>> 0);
            return ret;
        };
        imports.wbg.__wbg_new_with_str_and_init_c5748f76f5108934 = function() { return handleError(function (arg0, arg1, arg2) {
            const ret = new Request(getStringFromWasm0(arg0, arg1), arg2);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_next_138a17bbf04e926c = function(arg0) {
            const ret = arg0.next;
            return ret;
        };
        imports.wbg.__wbg_next_3cfe5c0fe2a4cc53 = function() { return handleError(function (arg0) {
            const ret = arg0.next();
            return ret;
        }, arguments) };
        imports.wbg.__wbg_node_905d3e251edff8a2 = function(arg0) {
            const ret = arg0.node;
            return ret;
        };
        imports.wbg.__wbg_now_2c95c9de01293173 = function(arg0) {
            const ret = arg0.now();
            return ret;
        };
        imports.wbg.__wbg_now_69d776cd24f5215b = function() {
            const ret = Date.now();
            return ret;
        };
        imports.wbg.__wbg_performance_7a3ffd0b17f663ad = function(arg0) {
            const ret = arg0.performance;
            return ret;
        };
        imports.wbg.__wbg_postMessage_07504dbe15265d5c = function() { return handleError(function (arg0, arg1) {
            arg0.postMessage(arg1);
        }, arguments) };
        imports.wbg.__wbg_postMessage_33814d4dc32c2dcf = function() { return handleError(function (arg0, arg1) {
            arg0.postMessage(arg1);
        }, arguments) };
        imports.wbg.__wbg_postMessage_7243f814e0cfb266 = function() { return handleError(function (arg0, arg1) {
            arg0.postMessage(arg1);
        }, arguments) };
        imports.wbg.__wbg_postMessage_e0309b53c7ad30e6 = function() { return handleError(function (arg0, arg1, arg2) {
            arg0.postMessage(arg1, arg2);
        }, arguments) };
        imports.wbg.__wbg_process_dc0fbacc7c1c06f7 = function(arg0) {
            const ret = arg0.process;
            return ret;
        };
        imports.wbg.__wbg_prototypesetcall_dfe9b766cdc1f1fd = function(arg0, arg1, arg2) {
            Uint8Array.prototype.set.call(getArrayU8FromWasm0(arg0, arg1), arg2);
        };
        imports.wbg.__wbg_push_7d9be8f38fc13975 = function(arg0, arg1) {
            const ret = arg0.push(arg1);
            return ret;
        };
        imports.wbg.__wbg_queueMicrotask_9b549dfce8865860 = function(arg0) {
            const ret = arg0.queueMicrotask;
            return ret;
        };
        imports.wbg.__wbg_queueMicrotask_fca69f5bfad613a5 = function(arg0) {
            queueMicrotask(arg0);
        };
        imports.wbg.__wbg_randomFillSync_ac0988aba3254290 = function() { return handleError(function (arg0, arg1) {
            arg0.randomFillSync(arg1);
        }, arguments) };
        imports.wbg.__wbg_require_60cc747a6bc5215a = function() { return handleError(function () {
            const ret = module.require;
            return ret;
        }, arguments) };
        imports.wbg.__wbg_resolve_fd5bfbaa4ce36e1e = function(arg0) {
            const ret = Promise.resolve(arg0);
            return ret;
        };
        imports.wbg.__wbg_setTimeout_7bb3429662ab1e70 = function(arg0, arg1) {
            const ret = setTimeout(arg0, arg1);
            return ret;
        };
        imports.wbg.__wbg_setTimeout_db2dbaeefb6f39c7 = function() { return handleError(function (arg0, arg1) {
            const ret = setTimeout(arg0, arg1);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_set_781438a03c0c3c81 = function() { return handleError(function (arg0, arg1, arg2) {
            const ret = Reflect.set(arg0, arg1, arg2);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_set_body_8e743242d6076a4f = function(arg0, arg1) {
            arg0.body = arg1;
        };
        imports.wbg.__wbg_set_cache_0e437c7c8e838b9b = function(arg0, arg1) {
            arg0.cache = __wbindgen_enum_RequestCache[arg1];
        };
        imports.wbg.__wbg_set_credentials_55ae7c3c106fd5be = function(arg0, arg1) {
            arg0.credentials = __wbindgen_enum_RequestCredentials[arg1];
        };
        imports.wbg.__wbg_set_headers_5671cf088e114d2b = function(arg0, arg1) {
            arg0.headers = arg1;
        };
        imports.wbg.__wbg_set_method_76c69e41b3570627 = function(arg0, arg1, arg2) {
            arg0.method = getStringFromWasm0(arg1, arg2);
        };
        imports.wbg.__wbg_set_mode_611016a6818fc690 = function(arg0, arg1) {
            arg0.mode = __wbindgen_enum_RequestMode[arg1];
        };
        imports.wbg.__wbg_set_onerror_d5671da43c08b208 = function(arg0, arg1) {
            arg0.onerror = arg1;
        };
        imports.wbg.__wbg_set_onmessage_deb94985de696ac7 = function(arg0, arg1) {
            arg0.onmessage = arg1;
        };
        imports.wbg.__wbg_set_signal_e89be862d0091009 = function(arg0, arg1) {
            arg0.signal = arg1;
        };
        imports.wbg.__wbg_set_type_7ce650670a34c68f = function(arg0, arg1, arg2) {
            arg0.type = getStringFromWasm0(arg1, arg2);
        };
        imports.wbg.__wbg_signal_3c14fbdc89694b39 = function(arg0) {
            const ret = arg0.signal;
            return ret;
        };
        imports.wbg.__wbg_stack_0ed75d68575b0f3c = function(arg0, arg1) {
            const ret = arg1.stack;
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg_static_accessor_GLOBAL_769e6b65d6557335 = function() {
            const ret = typeof global === 'undefined' ? null : global;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        };
        imports.wbg.__wbg_static_accessor_GLOBAL_THIS_60cf02db4de8e1c1 = function() {
            const ret = typeof globalThis === 'undefined' ? null : globalThis;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        };
        imports.wbg.__wbg_static_accessor_SELF_08f5a74c69739274 = function() {
            const ret = typeof self === 'undefined' ? null : self;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        };
        imports.wbg.__wbg_static_accessor_WINDOW_a8924b26aa92d024 = function() {
            const ret = typeof window === 'undefined' ? null : window;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        };
        imports.wbg.__wbg_status_9bfc680efca4bdfd = function(arg0) {
            const ret = arg0.status;
            return ret;
        };
        imports.wbg.__wbg_stringify_655a6390e1f5eb6b = function() { return handleError(function (arg0) {
            const ret = JSON.stringify(arg0);
            return ret;
        }, arguments) };
        imports.wbg.__wbg_subarray_845f2f5bce7d061a = function(arg0, arg1, arg2) {
            const ret = arg0.subarray(arg1 >>> 0, arg2 >>> 0);
            return ret;
        };
        imports.wbg.__wbg_text_51046bb33d257f63 = function() { return handleError(function (arg0) {
            const ret = arg0.text();
            return ret;
        }, arguments) };
        imports.wbg.__wbg_then_429f7caf1026411d = function(arg0, arg1, arg2) {
            const ret = arg0.then(arg1, arg2);
            return ret;
        };
        imports.wbg.__wbg_then_4f95312d68691235 = function(arg0, arg1) {
            const ret = arg0.then(arg1);
            return ret;
        };
        imports.wbg.__wbg_unshift_663583d1e06a5041 = function(arg0, arg1) {
            const ret = arg0.unshift(arg1);
            return ret;
        };
        imports.wbg.__wbg_url_b6d11838a4f95198 = function(arg0, arg1) {
            const ret = arg1.url;
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        };
        imports.wbg.__wbg_value_57b7b035e117f7ee = function(arg0) {
            const ret = arg0.value;
            return ret;
        };
        imports.wbg.__wbg_versions_c01dfd4722a88165 = function(arg0) {
            const ret = arg0.versions;
            return ret;
        };
        imports.wbg.__wbindgen_cast_0f5bbec71b79f586 = function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { dtor_idx: 498, function: Function { arguments: [NamedExternref("Event")], shim_idx: 499, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm.wasm_bindgen__closure__destroy__h0e24cf6e8491b288, wasm_bindgen__convert__closures_____invoke__h156dc1696d09afb9);
            return ret;
        };
        imports.wbg.__wbindgen_cast_2241b6af4c4b2941 = function(arg0, arg1) {
            // Cast intrinsic for `Ref(String) -> Externref`.
            const ret = getStringFromWasm0(arg0, arg1);
            return ret;
        };
        imports.wbg.__wbindgen_cast_4625c577ab2ec9ee = function(arg0) {
            // Cast intrinsic for `U64 -> Externref`.
            const ret = BigInt.asUintN(64, arg0);
            return ret;
        };
        imports.wbg.__wbindgen_cast_9ae0607507abb057 = function(arg0) {
            // Cast intrinsic for `I64 -> Externref`.
            const ret = arg0;
            return ret;
        };
        imports.wbg.__wbindgen_cast_b0d0da7787f356ae = function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { dtor_idx: 498, function: Function { arguments: [NamedExternref("MessageEvent")], shim_idx: 499, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm.wasm_bindgen__closure__destroy__h0e24cf6e8491b288, wasm_bindgen__convert__closures_____invoke__h156dc1696d09afb9);
            return ret;
        };
        imports.wbg.__wbindgen_cast_c22f63a81a5a9b13 = function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { dtor_idx: 619, function: Function { arguments: [], shim_idx: 620, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm.wasm_bindgen__closure__destroy__hdd50024ded2b6723, wasm_bindgen__convert__closures_____invoke__h517c9bfd8b0e7441);
            return ret;
        };
        imports.wbg.__wbindgen_cast_cb9088102bce6b30 = function(arg0, arg1) {
            // Cast intrinsic for `Ref(Slice(U8)) -> NamedExternref("Uint8Array")`.
            const ret = getArrayU8FromWasm0(arg0, arg1);
            return ret;
        };
        imports.wbg.__wbindgen_cast_d6cd19b81560fd6e = function(arg0) {
            // Cast intrinsic for `F64 -> Externref`.
            const ret = arg0;
            return ret;
        };
        imports.wbg.__wbindgen_cast_de4999e4c6d3415f = function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { dtor_idx: 752, function: Function { arguments: [], shim_idx: 753, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm.wasm_bindgen__closure__destroy__hf915667933809f2b, wasm_bindgen__convert__closures_____invoke__h125d5060f3bccfeb);
            return ret;
        };
        imports.wbg.__wbindgen_cast_f1c68a5d9b05547e = function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { dtor_idx: 786, function: Function { arguments: [Externref], shim_idx: 787, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm.wasm_bindgen__closure__destroy__h838a33a0c18a5e8b, wasm_bindgen__convert__closures_____invoke__h89b57d53ed7c2005);
            return ret;
        };
        imports.wbg.__wbindgen_init_externref_table = function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        };

        return imports;
    }

    function __wbg_finalize_init(instance, module) {
        wasm = instance.exports;
        __wbg_init.__wbindgen_wasm_module = module;
        cachedDataViewMemory0 = null;
        cachedUint8ArrayMemory0 = null;


        wasm.__wbindgen_start();
        return wasm;
    }

    function initSync(module) {
        if (wasm !== undefined) return wasm;


        if (typeof module !== 'undefined') {
            if (Object.getPrototypeOf(module) === Object.prototype) {
                ({module} = module)
            } else {
                console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
            }
        }

        const imports = __wbg_get_imports();
        if (!(module instanceof WebAssembly.Module)) {
            module = new WebAssembly.Module(module);
        }
        const instance = new WebAssembly.Instance(module, imports);
        return __wbg_finalize_init(instance, module);
    }

    async function __wbg_init(module_or_path) {
        if (wasm !== undefined) return wasm;


        if (typeof module_or_path !== 'undefined') {
            if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
                ({module_or_path} = module_or_path)
            } else {
                console.warn('using deprecated parameters for the initialization function; pass a single object instead')
            }
        }

        if (typeof module_or_path === 'undefined' && typeof script_src !== 'undefined') {
            module_or_path = script_src.replace(/\.js$/, '_bg.wasm');
        }
        const imports = __wbg_get_imports();

        if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
            module_or_path = fetch(module_or_path);
        }

        const { instance, module } = await __wbg_load(await module_or_path, imports);

        return __wbg_finalize_init(instance, module);
    }

    wasm_bindgen = Object.assign(__wbg_init, { initSync }, __exports);
})();
