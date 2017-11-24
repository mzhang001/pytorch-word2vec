import numpy as np
cimport numpy as np
import cython
from libc.stdio cimport FILE, fopen, fwrite, fscanf, fclose, fprintf, fseek, ftell, SEEK_END, rewind, fread
from libc.stdlib cimport malloc, free, rand, RAND_MAX
from libc.math cimport pow
from libc.stdint cimport uintptr_t

try:
    from scipy.linalg.blas import fblas
except ImportError:
    import scipy.linalg.blas as fblas

cdef extern from "voidptr.h":      
    void* PyCObject_AsVoidPtr(object obj)

ctypedef float (*sdot_ptr) (const int *N, const float *X, const int *incX, const float *Y, const int *incY) nogil  
ctypedef double (*snrm2_ptr) (const int *N, const float *X, const int *incX) nogil

cdef sdot_ptr sdot=<sdot_ptr>PyCObject_AsVoidPtr(fblas.sdot._cpointer)  # float = dot(x, y)
cdef snrm2_ptr snrm2=<snrm2_ptr>PyCObject_AsVoidPtr(fblas.snrm2._cpointer)  # sqrt(x^2)

def dot(int size, float[:] x, float[:] y):
    cdef int ONE = 1
    v1 = sdot(&size, &x[0], &ONE, &y[0], &ONE)
    return v1

#cdef cos_sim(int size, float[:] x, float[:] y):
#    cdef int ONE = 1
#    return sdot(&size, &x[0], &ONE, &y[0], &ONE) / snrm2(&size, &x[0], &ONE) / snrm2(&size, &y[0], &ONE)

cdef float cos_sim(const int size, const float* x, const float* y):
    cdef int ONE = 1
    return <float> sdot(&size, x, &ONE, y, &ONE) / snrm2(&size, x, &ONE) / snrm2(&size, y, &ONE)

cdef int* unigram_table

@cython.cdivision(True)
def init_unigram_table(word_list, freq, int train_words):
    global unigram_table
    cdef int table_size = int(1e8)
    cdef int a, idx, vocab_size 
    cdef double power = 0.75
    cdef double d1
    cdef double train_words_pow = 0.0
    unigram_table = <int *>malloc(table_size * sizeof(int));
    idx = 0
    vocab_size = len(word_list)

    for word in freq:
        train_words_pow += pow(freq[word], power)

    d1 = pow(freq[ word_list[idx] ], power) / train_words_pow;
    for a in range(table_size):
        unigram_table[a] = idx
        if (<double>a / table_size) > d1:
            idx += 1
            d1 += pow(freq[ word_list[idx] ], power) / train_words_pow;
        if idx >= vocab_size:
            idx = vocab_size - 1;
            
    return <uintptr_t>unigram_table

cdef int get_unigram_table_at_idx(int* arr, unsigned long long next_random):
    #return *(arr + ((next_random >> 16) % 100000000))
    return arr [ (next_random >> 16) % 100000000 ]
#def test_ptr(uintptr_t ptr_val):
#    cdef int* unigram_table
#    unigram_table = <int*>ptr_val
#    return [ unigram_table[a] for a in range(int(1e8)) ]

#cdef uniform():
#    return <double> rand() / RAND_MAX

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def cbow_producer(sent_id, int sent_id_len, uintptr_t ptr_val, int window, int negative, int vocab_size, int batch_size, unsigned long long next_random, bint dynamic_window=True):
    cdef int i,j,tar_id,pos,t,n,q,r
    cdef int ctx_pos, ctx_count, neg_count, actual_window
    cdef unsigned long long modulo = 281474976710655ULL
    
    # columns of data and its length:  
    #   ctx_indices:  [2 * window]
    #   ctx_lens:     [1]
    #   word_idx:     [1]
    #   neg_indices:  [negative]
    #   neg_mask:     [negative]
    cdef long[:,:] data = np.zeros([sent_id_len,2*window+1+1+2*negative], dtype=np.int64)

    cdef int* unigram_table
    unigram_table = <int*>ptr_val

    for i in range(sent_id_len):
        #ctx_pos = 0
        ctx_count = 0
        actual_window = rand() % window + 1 if dynamic_window else window
        tar_id = sent_id[i]
        for j in range(i-window, i-actual_window):
            pos = j - (i-window)
            data[i, pos] = vocab_size
        for j in range(i-actual_window, i):
            pos = j - (i-window)
            if j < 0 or j >= sent_id_len:
                data[i, pos] = vocab_size
            else:
                data[i, pos] = sent_id[j]
                ctx_count += 1
        for j in range(i+1, i+1+actual_window):
            pos = j - (i-window) - 1
            if j < 0 or j >= sent_id_len:
                data[i, pos] = vocab_size
            else:
                data[i, pos] = sent_id[j]
                ctx_count += 1
        for j in range(i+1+actual_window, i+1+window):
            pos = j - (i-window) - 1
            data[i, pos] = vocab_size
        '''
        for j in range(i-actual_window, i+actual_window+1):
            if j == i:
                continue
            if j < 0 or j >= sent_id_len:
                data[i, j] = vocab_size
                #continue
            else:
                data[i, ctx_count] = sent_id[j]
                ctx_count += 1
        for j in range(ctx_count, 2*window+1):
            data[i, j] = vocab_size
        '''
        data[i, 2*window] = ctx_count
        data[i, 2*window+1] = tar_id

        # negative sampling
        neg_count = 0
        for n in range(negative):
            #t= unigram_table[ (next_random >> 16) % int(1e8) ]
            t = get_unigram_table_at_idx(unigram_table, next_random)
            next_random = (next_random * <unsigned long long>25214903917ULL + 11) & modulo
            #t = rand() % vocab_size
            #t = unigram_table[ <int>(<double>(rand()>>16) / RAND_MAX * 1e8) ]
            #t = unigram_table[ <int>(<double> rand() / RAND_MAX * 1e8) ]
            #t = unigram_table[ rand() % 1e8 ]
            #t = rand() % 1e8 ]
            if t == tar_id:
                continue

            data[i, 2*window+2+neg_count] = t
            neg_count += 1

        # neg mask
        for n in range(neg_count):
            data[i, 2*window+2+negative+n] = 1

    # batch generator 
    q = sent_id_len // batch_size
    r = sent_id_len % batch_size
    if q > 0:
        for i in range(q):
            yield np.asarray(data[i*batch_size:(i+1)*batch_size, :])
        if r > 0:
            yield np.asarray(data[sent_id_len-r:sent_id_len, :])
    else:
        yield np.asarray(data)


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def sg_producer(sent_id, int sent_id_len, uintptr_t ptr_val, int window, int negative, int vocab_size, int batch_size, unsigned long long next_random, bint dynamic_window=True):
    cdef int i,j,t,n,q,r
    cdef int batch_count, neg_count, actual_window
    cdef unsigned long long modulo = 281474976710655ULL

    # columns of data and its length:  
    #   word_idx:     [1]
    #   ctx_idx:      [1]
    #   neg_indices:  [negative]
    #   neg_mask:     [negative]
    #cdef long[:,:] data = np.zeros([batch_size, 2+2*negative], dtype=np.int64)
    cdef long[:,:] data = np.zeros([sent_id_len*2*window, 2+2*negative], dtype=np.int64)

    cdef int* unigram_table
    unigram_table = <int*>ptr_val

    batch_count = 0
    for i in range(sent_id_len):
        actual_window = rand() % window + 1 if dynamic_window else window
        for j in range(i-actual_window, i+actual_window+1):
            if j < 0 or j >= sent_id_len or j == i:
                continue
            
            data[batch_count, 0] = sent_id[j]
            data[batch_count, 1] = sent_id[i]
            
            # negative sampling
            neg_count = 0
            for n in range(negative):
                t= unigram_table[ (next_random >> 16) % int(1e8) ]
                next_random = (next_random * <unsigned long long>25214903917ULL + 11) & modulo
                if t == sent_id[i]:
                    continue

                data[batch_count, 2+neg_count] = t
                neg_count += 1

            # neg mask
            for n in range(neg_count):
                data[batch_count, 2+negative+n] = 1

            batch_count += 1 

            # if batch_count reaches batch_size 
            #if batch_count >= batch_size:
            #    yield np.asarray(data)
            #    batch_count = 0 

    q = batch_count // batch_size
    r = batch_count % batch_size
    if q > 0:
        for i in range(q):
            yield np.asarray(data[i*batch_size:(i+1)*batch_size, :])
        if r > 0:
            yield np.asarray(data[batch_count-r:batch_count, :])
    else:
        #yield np.asarray(data)
        yield np.asarray(data[:batch_count, :])
    # the remaining data 
    #if batch_count > 0:
    #    yield np.asarray(data[:batch_count, :])


def write_embs(str fn, word_list, float[:,:] embs, int vocab_size, int dim):
    cdef int i,j
    #fo = fopen(fn, "rb") 
    #out_f.write('</s>\t')
    with open(fn, 'w') as out_f:
        out_f.write('%d\t%d\n' % (vocab_size+1, dim));
        #out_f.write('%d\t%d\n' % (vocab_size, dim));

        out_f.write('</s>\t')
        for j in range(dim):
            #out_f.write( '%.18f\t' % embs[vocab_size, j] )
            out_f.write( '%.6f\t' % embs[vocab_size, j] )
        out_f.write('\n')

        for i in range(vocab_size):
            out_f.write('%s\t' % word_list[i])
            for j in range(dim):
                #out_f.write( '%.18f\t' % embs[i, j] )
                out_f.write( '%.6f\t' % embs[i, j] )
            out_f.write('\n')
        

#def create_n_select_sense(long[:,:] chunk, float[:,:] context_feats, float[:,:] sense_embs, word2sense, creates, int chunk_size, int emb_dim, int window, int negative, float delta, int current_n_sense):
def create_n_select_sense(long[:,:] chunk, float[:,:] context_feats, sense2idx, float[:,:] sense_embs, word2sense, int chunk_size, int n_sense_emb, int emb_dim, int window, float delta, int current_n_sense):
#def create_n_select_sense(long[:,:] chunk, float[:,:] context_feats, sense2idx_dict, float[:,:] sense_embs, word2sense, creates, int chunk_size, int emb_dim, int window, int negative, float delta, int current_n_sense):
    cdef int b, d, pos, t_id, s_id
    cdef int max_sense_id, create_count, select_count
    cdef float sim, max_sim
    cdef long[:,:] data = np.zeros([chunk_size, 2*window+2], dtype=np.int64)

    create_count = 0
    select_count = 0
    for b in range(chunk_size):
        t_id = chunk[b, 2*window+1]
        max_sense_id = -1
        max_sim = delta 
        for s_id in word2sense[t_id]:
            sim = cos_sim(emb_dim, &context_feats[b,0], &sense_embs[sense2idx[s_id],0])
            if sim > max_sim:
                sim = max_sim
                max_sense_id = s_id

        if max_sense_id == -1:
            new_sense_id = current_n_sense + create_count
            word2sense[t_id].append(new_sense_id)
            sense2idx[new_sense_id] = n_sense_emb + create_count
            sense_embs[n_sense_emb+create_count, :] = context_feats[b, :]
            create_count += 1
        else:
            data[select_count, :] = chunk[b, :]
            data[select_count, 2*window+1] = max_sense_id
            select_count += 1

    return data[:select_count, :], sense_embs[n_sense_emb:n_sense_emb+create_count, :]

'''
def select_sense(long[:,:] type_mat, float[:,:] context_feats, float[:,:] sense_embs, word2sense, creates, int batch_size, int emb_dim, int negative, int current_n_sense):
'''
def select_sense(long[:,:] chunk, float[:,:] context_feats, sense2idx, float[:,:] sense_embs, word2sense, int chunk_size, int emb_dim, int window, int negative):
    cdef int b, d, pos, t_id, s_id
    cdef int max_sense_id
    cdef float sim, max_sim
    #cdef long[:,:] data = np.zeros([chunk_size, 2*window+2+2*negative], dtype=np.int64)

    for b in range(chunk_size):
        for pos in range(2*window+1, 2*window+2+2*negative):
            t_id = chunk[b, pos]
            max_sense_id = -1
            max_sim = -10.0
            for s_id in word2sense[t_id]:
                sim = cos_sim(emb_dim, &context_feats[b,0], &sense_embs[sense2idx[s_id],0])
                if sim > max_sim:
                    sim = max_sim
                    max_sense_id = s_id

            chunk[b, pos] = max_sense_id

    return chunk

