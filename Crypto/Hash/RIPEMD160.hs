{-# LANGUAGE ForeignFunctionInterface, CPP, MultiParamTypeClasses #-}

-- |
-- Module      : Crypto.Hash.RIPEMD160
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- A module containing RIPEMD160 bindings
--
module Crypto.Hash.RIPEMD160
    ( Ctx(..)
    , RIPEMD160

    -- * Incremental hashing Functions
    , init     -- :: Ctx
    , update   -- :: Ctx -> ByteString -> Ctx
    , updates  -- :: Ctx -> [ByteString] -> Ctx
    , finalize -- :: Ctx -> ByteString

    -- * Single Pass hashing
    , hash     -- :: ByteString -> ByteString
    , hashlazy -- :: ByteString -> ByteString
    ) where

import Prelude hiding (init)
import Foreign.Ptr
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable
import Foreign.Marshal.Alloc
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.ByteString.Internal (create, toForeignPtr)
import Data.Word
import Crypto.Hash.Internal (unsafeDoIO)

#ifdef HAVE_CRYPTOAPI

import Control.Monad (liftM)
import Data.Serialize (Serialize(..))
import Data.Serialize.Get (getByteString)
import Data.Serialize.Put (putByteString)
import Data.Tagged (Tagged(..))
import qualified Crypto.Classes as C (Hash(..))

instance C.Hash Ctx RIPEMD160 where
    outputLength    = Tagged (20 * 8)
    blockLength     = Tagged (64 * 8)
    initialCtx      = init
    updateCtx       = update
    finalize ctx bs = Digest . finalize $ update ctx bs

instance Serialize RIPEMD160 where
    get            = liftM Digest (getByteString digestSize)
    put (Digest d) = putByteString d

#endif

newtype Ctx = Ctx ByteString
data RIPEMD160 = Digest !ByteString
    deriving (Eq,Ord,Show)


{-# INLINE digestSize #-}
digestSize :: Int
digestSize = 20

{-# INLINE sizeCtx #-}
sizeCtx :: Int
sizeCtx = 128

{-# RULES "digestSize" B.length (finalize init) = digestSize #-}
{-# RULES "hash" forall b. finalize (update init b) = hash b #-}
{-# RULES "hash.list1" forall b. finalize (updates init [b]) = hash b #-}
{-# RULES "hashmany" forall b. finalize (foldl update init b) = hashlazy (L.fromChunks b) #-}
{-# RULES "hashlazy" forall b. finalize (foldl update init $ L.toChunks b) = hashlazy b #-}

{-# INLINE withByteStringPtr #-}
withByteStringPtr :: ByteString -> (Ptr Word8 -> IO a) -> IO a
withByteStringPtr b f =
    withForeignPtr fptr $ \ptr -> f (ptr `plusPtr` off)
    where (fptr, off, _) = toForeignPtr b

{-# INLINE memcopy64 #-}
memcopy64 :: Ptr Word64 -> Ptr Word64 -> IO ()
memcopy64 dst src = mapM_ peekAndPoke [0..(16-1)]
    where peekAndPoke i = peekElemOff src i >>= pokeElemOff dst i

withCtxCopy :: Ctx -> (Ptr Ctx -> IO ()) -> IO Ctx
withCtxCopy (Ctx ctxB) f = Ctx `fmap` createCtx
    where createCtx = create sizeCtx $ \dstPtr ->
                      withByteStringPtr ctxB $ \srcPtr -> do
                          memcopy64 (castPtr dstPtr) (castPtr srcPtr)
                          f (castPtr dstPtr)

withCtxThrow :: Ctx -> (Ptr Ctx -> IO a) -> IO a
withCtxThrow (Ctx ctxB) f =
    allocaBytes sizeCtx $ \dstPtr ->
    withByteStringPtr ctxB $ \srcPtr -> do
        memcopy64 (castPtr dstPtr) (castPtr srcPtr)
        f (castPtr dstPtr)

withCtxNew :: (Ptr Ctx -> IO ()) -> IO Ctx
withCtxNew f = Ctx `fmap` create sizeCtx (f . castPtr)

withCtxNewThrow :: (Ptr Ctx -> IO a) -> IO a
withCtxNewThrow f = allocaBytes sizeCtx (f . castPtr)

foreign import ccall unsafe "ripemd.h ripemd160_init"
    c_ripemd160_init :: Ptr Ctx -> IO ()

foreign import ccall "ripemd.h ripemd160_update"
    c_ripemd160_update :: Ptr Ctx -> Ptr Word8 -> Word32 -> IO ()

foreign import ccall unsafe "ripemd.h ripemd160_finalize"
    c_ripemd160_finalize :: Ptr Ctx -> Ptr Word8 -> IO ()

updateInternalIO :: Ptr Ctx -> ByteString -> IO ()
updateInternalIO ptr d =
    unsafeUseAsCStringLen d (\(cs, len) -> c_ripemd160_update ptr (castPtr cs) (fromIntegral len))

finalizeInternalIO :: Ptr Ctx -> IO ByteString
finalizeInternalIO ptr = create digestSize (c_ripemd160_finalize ptr)

{-# NOINLINE init #-}
-- | init a context
init :: Ctx
init = unsafeDoIO $ withCtxNew $ c_ripemd160_init

{-# NOINLINE update #-}
-- | update a context with a bytestring
update :: Ctx -> ByteString -> Ctx
update ctx d = unsafeDoIO $ withCtxCopy ctx $ \ptr -> updateInternalIO ptr d

{-# NOINLINE updates #-}
-- | updates a context with multiples bytestring
updates :: Ctx -> [ByteString] -> Ctx
updates ctx d = unsafeDoIO $ withCtxCopy ctx $ \ptr -> mapM_ (updateInternalIO ptr) d

{-# NOINLINE finalize #-}
-- | finalize the context into a digest bytestring
finalize :: Ctx -> ByteString
finalize ctx = unsafeDoIO $ withCtxThrow ctx finalizeInternalIO

{-# NOINLINE hash #-}
-- | hash a strict bytestring into a digest bytestring
hash :: ByteString -> ByteString
hash d = unsafeDoIO $ withCtxNewThrow $ \ptr -> do
    c_ripemd160_init ptr >> updateInternalIO ptr d >> finalizeInternalIO ptr

{-# NOINLINE hashlazy #-}
-- | hash a lazy bytestring into a digest bytestring
hashlazy :: L.ByteString -> ByteString
hashlazy l = unsafeDoIO $ withCtxNewThrow $ \ptr -> do
    c_ripemd160_init ptr >> mapM_ (updateInternalIO ptr) (L.toChunks l) >> finalizeInternalIO ptr
