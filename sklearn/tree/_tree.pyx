# encoding: utf-8
# cython: cdivision=True
# cython: boundscheck=True
# cython: wraparound=True

# Authors: Gilles Louppe <g.louppe@gmail.com>
#          Peter Prettenhofer <peter.prettenhofer@gmail.com>
#          Brian Holt <bdholt1@gmail.com>
#          Noel Dawe <noel@dawe.me>
#          Satrajit Gosh <satrajit.ghosh@gmail.com>
# Licence: BSD 3 clause


from libc.stdlib cimport calloc, free, malloc, realloc
from libc.string cimport memcpy
from libc.math cimport log2 as log

import numpy as np
cimport numpy as np
np.import_array()

cdef extern:
    int sklearn_rand_r(unsigned int *seedp) nogil

cdef enum:
    # XXX we should put this in a header somewhere
    RAND_MAX = 0x7FFFFFFF


# =============================================================================
# Types and constants
# =============================================================================

from numpy import float32 as DTYPE
from numpy import float64 as DOUBLE

cdef double INFINITY = np.inf
TREE_LEAF = -1
TREE_UNDEFINED = -2
cdef SIZE_t _TREE_LEAF = TREE_LEAF
cdef SIZE_t _TREE_UNDEFINED = TREE_UNDEFINED


# =============================================================================
# Criterion
# =============================================================================

cdef class Criterion:
    """Interface for impurity criteria."""

    cdef void init(self, DOUBLE_t* y,
                         SIZE_t y_stride,
                         DOUBLE_t* sample_weight,
                         SIZE_t* samples,
                         SIZE_t start,
                         SIZE_t end) nogil:
        """Initialize the criterion at node samples[start:end] and
           children samples[start:start] and samples[start:end]."""
        pass

    cdef void reset(self) nogil:
        """Reset the criterion at pos=start."""
        pass

    cdef void update(self, SIZE_t new_pos) nogil:
        """Update the collected statistics by moving samples[pos:new_pos] from
           the right child to the left child."""
        pass

    cdef double node_impurity(self) nogil:
        """Evaluate the impurity of the current node, i.e. the impurity of
           samples[start:end]."""
        pass

    cdef double children_impurity(self) nogil:
        """Evaluate the impurity in children nodes, i.e. the impurity of
           samples[start:pos] + the impurity of samples[pos:end]."""
        pass

    cdef void node_value(self, double* dest) nogil:
        """Compute the node value of samples[start:end] into dest."""
        pass


cdef class ClassificationCriterion(Criterion):
    """Abstract criterion for classification."""
    cdef SIZE_t* n_classes
    cdef SIZE_t label_count_stride
    cdef double* label_count_left
    cdef double* label_count_right
    cdef double* label_count_total

    def __cinit__(self, SIZE_t n_outputs, np.ndarray[SIZE_t, ndim=1] n_classes):
        # Default values
        self.y = NULL
        self.y_stride = 0
        self.sample_weight = NULL

        self.samples = NULL
        self.start = 0
        self.pos = 0
        self.end = 0

        self.n_outputs = n_outputs
        self.n_node_samples = 0
        self.weighted_n_node_samples = 0.0
        self.weighted_n_left = 0.0
        self.weighted_n_right = 0.0

        # Count labels for each output
        self.n_classes = <SIZE_t*> malloc(n_outputs * sizeof(SIZE_t))
        if self.n_classes == NULL:
            raise MemoryError()

        cdef SIZE_t k = 0
        cdef SIZE_t label_count_stride = 0

        for k from 0 <= k < n_outputs:
            self.n_classes[k] = n_classes[k]

            if n_classes[k] > label_count_stride:
                label_count_stride = n_classes[k]

        self.label_count_stride = label_count_stride

        # Allocate counters
        self.label_count_left = <double*> calloc(n_outputs * label_count_stride, sizeof(double))
        self.label_count_right = <double*> calloc(n_outputs * label_count_stride, sizeof(double))
        self.label_count_total = <double*> calloc(n_outputs * label_count_stride, sizeof(double))

        # Check for allocation errors
        if ((self.label_count_left == NULL) or
            (self.label_count_right == NULL) or
            (self.label_count_total == NULL)):
            free(self.n_classes)
            free(self.label_count_left)
            free(self.label_count_right)
            free(self.label_count_total)
            raise MemoryError()

    def __dealloc__(self):
        """Destructor."""
        free(self.n_classes)
        free(self.label_count_left)
        free(self.label_count_right)
        free(self.label_count_total)

    def __reduce__(self):
        return (ClassificationCriterion,
                (self.n_outputs,
                 sizet_ptr_to_ndarray(self.n_classes, self.n_outputs)),
                self.__getstate__())

    def __getstate__(self):
        return {}

    def __setstate__(self, d):
        pass

    cdef void init(self, DOUBLE_t* y,
                         SIZE_t y_stride,
                         DOUBLE_t* sample_weight,
                         SIZE_t* samples,
                         SIZE_t start,
                         SIZE_t end) nogil:
        """Initialize the criterion at node samples[start:end] and
           children samples[start:start] and samples[start:end]."""
        # Initialize fields
        self.y = y
        self.y_stride = y_stride
        self.sample_weight = sample_weight
        self.samples = samples
        self.start = start
        self.end = end
        self.n_node_samples = end - start
        cdef double weighted_n_node_samples = 0.0

        # Initialize label_count_total and weighted_n_node_samples
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total

        cdef SIZE_t i = 0
        cdef SIZE_t p = 0
        cdef SIZE_t k = 0
        cdef SIZE_t c = 0
        cdef DOUBLE_t w = 1.0
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            for c from 0 <= c < n_classes[k]:
                label_count_total[offset + c] = 0
            offset += label_count_stride

        for p from start <= p < end:
            i = samples[p]

            if sample_weight != NULL:
                w = sample_weight[i]

            for k from 0 <= k < n_outputs:
                c = <SIZE_t> y[i * y_stride + k]
                label_count_total[k * label_count_stride + c] += w

            weighted_n_node_samples += w

        self.weighted_n_node_samples = weighted_n_node_samples

        # Reset to pos=start
        self.reset()

    cdef void reset(self) nogil:
        """Reset the criterion at pos=start."""
        self.pos = self.start

        self.weighted_n_left = 0.0
        self.weighted_n_right = self.weighted_n_node_samples

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total
        cdef double* label_count_left = self.label_count_left
        cdef double* label_count_right = self.label_count_right

        cdef SIZE_t k = 0
        cdef SIZE_t c = 0
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            for c from 0 <= c < n_classes[k]:
                # Reset left label counts to 0
                label_count_left[offset + c] = 0
                # Reset right label counts to the initial counts
                label_count_right[offset + c] = label_count_total[offset + c]
            offset += label_count_stride

    cdef void update(self, SIZE_t new_pos) nogil:
        """Update the collected statistics by moving samples[pos:new_pos] from
            the right child to the left child."""
        cdef DOUBLE_t* y = self.y
        cdef SIZE_t y_stride = self.y_stride
        cdef DOUBLE_t* sample_weight = self.sample_weight

        cdef SIZE_t* samples = self.samples
        cdef SIZE_t pos = self.pos

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total
        cdef double* label_count_left = self.label_count_left
        cdef double* label_count_right = self.label_count_right

        cdef double weighted_n_left = self.weighted_n_left
        cdef double weighted_n_right = self.weighted_n_right

        cdef SIZE_t i
        cdef SIZE_t p
        cdef SIZE_t k
        cdef SIZE_t label_index
        cdef DOUBLE_t w = 1.0

        # Note: We assume start <= pos < new_pos <= end

        for p from pos <= p < new_pos:
            i = samples[p]

            if sample_weight != NULL:
                w  = sample_weight[i]

            for k from 0 <= k < n_outputs:
                label_index = (k * label_count_stride +
                               <SIZE_t> y[i * y_stride + k])
                label_count_left[label_index] += w
                label_count_right[label_index] -= w

            weighted_n_left += w
            weighted_n_right -= w

        self.weighted_n_left = weighted_n_left
        self.weighted_n_right = weighted_n_right

        self.pos = new_pos

    cdef double node_impurity(self) nogil:
        pass

    cdef double children_impurity(self) nogil:
        pass

    cdef void node_value(self, double* dest) nogil:
        """Compute the node value of samples[start:end] into dest."""
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total

        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            for c from 0 <= c < n_classes[k]:
                dest[offset + c] = label_count_total[offset + c]
            offset += label_count_stride


cdef class Entropy(ClassificationCriterion):
    """Cross Entropy impurity criteria.

    Let the target be a classification outcome taking values in 0, 1, ..., K-1.
    If node m represents a region Rm with Nm observations, then let

        pmk = 1/ Nm \sum_{x_i in Rm} I(yi = k)

    be the proportion of class k observations in node m.

    The cross-entropy is then defined as

        cross-entropy = - \sum_{k=0}^{K-1} pmk log(pmk)
    """
    cdef double node_impurity(self) nogil:
        """Evaluate the impurity of the current node, i.e. the impurity of
           samples[start:end]."""
        cdef double weighted_n_node_samples = self.weighted_n_node_samples

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total

        cdef double entropy = 0.0
        cdef double total = 0.0
        cdef double tmp
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            entropy = 0.0

            for c from 0 <= c < n_classes[k]:
                tmp = label_count_total[offset + c]
                if tmp > 0.0:
                    tmp /= weighted_n_node_samples
                    entropy -= tmp * log(tmp)

            total += entropy
            offset += label_count_stride

        return total / n_outputs

    cdef double children_impurity(self) nogil:
        """Evaluate the impurity in children nodes, i.e. the impurity of
           samples[start:pos] + the impurity of samples[pos:end]."""
        cdef double weighted_n_node_samples = self.weighted_n_node_samples
        cdef double weighted_n_left = self.weighted_n_left
        cdef double weighted_n_right = self.weighted_n_right

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_left = self.label_count_left
        cdef double* label_count_right = self.label_count_right

        cdef double entropy_left = 0.0
        cdef double entropy_right = 0.0
        cdef double total = 0.0
        cdef double tmp
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            entropy_left = 0.0
            entropy_right = 0.0

            for c from 0 <= c < n_classes[k]:
                tmp = label_count_left[offset + c]
                if tmp > 0.0:
                    tmp /= weighted_n_left
                    entropy_left -= tmp * log(tmp)

                tmp = label_count_right[offset + c]
                if tmp > 0.0:
                    tmp /= weighted_n_right
                    entropy_right -= tmp * log(tmp)

            total += weighted_n_left * entropy_left
            total += weighted_n_right * entropy_right
            offset += label_count_stride

        return total / (weighted_n_node_samples * n_outputs)


cdef class Gini(ClassificationCriterion):
    """Gini Index impurity criteria.

    Let the target be a classification outcome taking values in 0, 1, ..., K-1.
    If node m represents a region Rm with Nm observations, then let

        pmk = 1/ Nm \sum_{x_i in Rm} I(yi = k)

    be the proportion of class k observations in node m.

    The Gini Index is then defined as:

        index = \sum_{k=0}^{K-1} pmk (1 - pmk)
              = 1 - \sum_{k=0}^{K-1} pmk ** 2
    """
    cdef double node_impurity(self) nogil:
        """Evaluate the impurity of the current node, i.e. the impurity of
           samples[start:end]."""
        cdef double weighted_n_node_samples = self.weighted_n_node_samples

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_total = self.label_count_total

        cdef double gini = 0.0
        cdef double total = 0.0
        cdef double tmp
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            gini = 0.0

            for c from 0 <= c < n_classes[k]:
                tmp = label_count_total[offset + c]
                gini += tmp * tmp

            gini = 1.0 - gini / (weighted_n_node_samples *
                                 weighted_n_node_samples)

            total += gini
            offset += label_count_stride

        return total / n_outputs

    cdef double children_impurity(self) nogil:
        """Evaluate the impurity in children nodes, i.e. the impurity of
           samples[start:pos] + the impurity of samples[pos:end]."""
        cdef double weighted_n_node_samples = self.weighted_n_node_samples
        cdef double weighted_n_left = self.weighted_n_left
        cdef double weighted_n_right = self.weighted_n_right

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t label_count_stride = self.label_count_stride
        cdef double* label_count_left = self.label_count_left
        cdef double* label_count_right = self.label_count_right

        cdef double gini_left = 0.0
        cdef double gini_right = 0.0
        cdef double total = 0.0
        cdef double tmp
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t offset = 0

        for k from 0 <= k < n_outputs:
            gini_left = 0.0
            gini_right = 0.0

            for c from 0 <= c < n_classes[k]:
                tmp = label_count_left[offset + c]
                gini_left += tmp * tmp
                tmp = label_count_right[offset + c]
                gini_right += tmp * tmp

            gini_left = 1.0 - gini_left / (weighted_n_left *
                                           weighted_n_left)
            gini_right = 1.0 - gini_right / (weighted_n_right *
                                             weighted_n_right)

            total += weighted_n_left * gini_left
            total += weighted_n_right * gini_right
            offset += label_count_stride

        return total / (weighted_n_node_samples * n_outputs)


cdef class RegressionCriterion(Criterion):
    """Abstract criterion for regression.

    Computes variance of the target values left and right of the split point.
    Computation is linear in `n_samples` by using ::

        var = \sum_i^n (y_i - y_bar) ** 2
            = (\sum_i^n y_i ** 2) - n_samples y_bar ** 2
    """
    cdef double* mean_left
    cdef double* mean_right
    cdef double* mean_total
    cdef double* sq_sum_left
    cdef double* sq_sum_right
    cdef double* sq_sum_total
    cdef double* var_left
    cdef double* var_right

    def __cinit__(self, SIZE_t n_outputs):
        # Default values
        self.y = NULL
        self.y_stride = 0
        self.sample_weight = NULL

        self.samples = NULL
        self.start = 0
        self.pos = 0
        self.end = 0

        self.n_outputs = n_outputs
        self.n_node_samples = 0
        self.weighted_n_node_samples = 0.0
        self.weighted_n_left = 0.0
        self.weighted_n_right = 0.0

        # Allocate accumulators
        self.mean_left = <double*> calloc(n_outputs, sizeof(double))
        self.mean_right = <double*> calloc(n_outputs, sizeof(double))
        self.mean_total = <double*> calloc(n_outputs, sizeof(double))
        self.sq_sum_left = <double*> calloc(n_outputs, sizeof(double))
        self.sq_sum_right = <double*> calloc(n_outputs, sizeof(double))
        self.sq_sum_total = <double*> calloc(n_outputs, sizeof(double))
        self.var_left = <double*> calloc(n_outputs, sizeof(double))
        self.var_right = <double*> calloc(n_outputs, sizeof(double))

        # Check for allocation errors
        if ((self.mean_left == NULL) or
            (self.mean_right == NULL) or
            (self.mean_total == NULL) or
            (self.sq_sum_left == NULL) or
            (self.sq_sum_right == NULL) or
            (self.sq_sum_total == NULL) or
            (self.var_left == NULL) or
            (self.var_right == NULL)):
            free(self.mean_left)
            free(self.mean_right)
            free(self.mean_total)
            free(self.sq_sum_left)
            free(self.sq_sum_right)
            free(self.sq_sum_total)
            free(self.var_left)
            free(self.var_right)
            raise MemoryError()

    def __dealloc__(self):
        """Destructor."""
        free(self.mean_left)
        free(self.mean_right)
        free(self.mean_total)
        free(self.sq_sum_left)
        free(self.sq_sum_right)
        free(self.sq_sum_total)
        free(self.var_left)
        free(self.var_right)

    def __reduce__(self):
        return (RegressionCriterion, (self.n_outputs,), self.__getstate__())

    def __getstate__(self):
        return {}

    def __setstate__(self, d):
        pass

    cdef void init(self, DOUBLE_t* y,
                         SIZE_t y_stride,
                         DOUBLE_t* sample_weight,
                         SIZE_t* samples,
                         SIZE_t start,
                         SIZE_t end) nogil:
        """Initialize the criterion at node samples[start:end] and
           children samples[start:start] and samples[start:end]."""
        # Initialize fields
        self.y = y
        self.y_stride = y_stride
        self.sample_weight = sample_weight
        self.samples = samples
        self.start = start
        self.end = end
        self.n_node_samples = end - start
        cdef double weighted_n_node_samples = 0.

        # Initialize accumulators
        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* mean_left = self.mean_left
        cdef double* mean_right = self.mean_right
        cdef double* mean_total = self.mean_total
        cdef double* sq_sum_left = self.sq_sum_left
        cdef double* sq_sum_right = self.sq_sum_right
        cdef double* sq_sum_total = self.sq_sum_total
        cdef double* var_left = self.var_left
        cdef double* var_right = self.var_right

        cdef SIZE_t i = 0
        cdef SIZE_t p = 0
        cdef SIZE_t k = 0
        cdef DOUBLE_t y_ik = 0.0
        cdef DOUBLE_t w = 1.0

        for k from 0 <= k < n_outputs:
            mean_left[k] = 0.0
            mean_right[k] = 0.0
            mean_total[k] = 0.0
            sq_sum_right[k] = 0.0
            sq_sum_left[k] = 0.0
            sq_sum_total[k] = 0.0
            var_left[k] = 0.0
            var_right[k] = 0.0

        for p from start <= p < end:
            i = samples[p]

            if sample_weight != NULL:
                w = sample_weight[i]

            for k from 0 <= k < n_outputs:
                y_ik = y[i * y_stride + k]
                sq_sum_total[k] += w * y_ik * y_ik
                mean_total[k] += w * y_ik

            weighted_n_node_samples += w

        self.weighted_n_node_samples = weighted_n_node_samples

        for k from 0 <= k < n_outputs:
            mean_total[k] /= weighted_n_node_samples

        # Reset to pos=start
        self.reset()

    cdef void reset(self) nogil:
        """Reset the criterion at pos=start."""
        self.pos = self.start

        self.weighted_n_left = 0.0
        self.weighted_n_right = self.weighted_n_node_samples

        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* mean_left = self.mean_left
        cdef double* mean_right = self.mean_right
        cdef double* mean_total = self.mean_total
        cdef double* sq_sum_left = self.sq_sum_left
        cdef double* sq_sum_right = self.sq_sum_right
        cdef double* sq_sum_total = self.sq_sum_total
        cdef double* var_left = self.var_left
        cdef double* var_right = self.var_right
        cdef double weighted_n_node_samples = self.weighted_n_node_samples

        cdef SIZE_t k = 0

        for k from 0 <= k < n_outputs:
            mean_right[k] = mean_total[k]
            mean_left[k] = 0.0
            sq_sum_right[k] = sq_sum_total[k]
            sq_sum_left[k] = 0.0
            var_left[k] = 0.0
            var_right[k] = (sq_sum_right[k] -
                            weighted_n_node_samples * (mean_right[k] *
                                                       mean_right[k]))

    cdef void update(self, SIZE_t new_pos) nogil:
        """Update the collected statistics by moving samples[pos:new_pos] from
           the right child to the left child."""
        cdef DOUBLE_t* y = self.y
        cdef SIZE_t y_stride = self.y_stride
        cdef DOUBLE_t* sample_weight = self.sample_weight

        cdef SIZE_t* samples = self.samples
        cdef SIZE_t pos = self.pos

        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* mean_left = self.mean_left
        cdef double* mean_right = self.mean_right
        cdef double* sq_sum_left = self.sq_sum_left
        cdef double* sq_sum_right = self.sq_sum_right
        cdef double* var_left = self.var_left
        cdef double* var_right = self.var_right

        cdef double weighted_n_left = self.weighted_n_left
        cdef double weighted_n_right = self.weighted_n_right

        cdef SIZE_t i
        cdef SIZE_t p
        cdef SIZE_t k
        cdef DOUBLE_t w = 1.0
        cdef DOUBLE_t y_ik, w_y_ik

        # Note: We assume start <= pos < new_pos <= end

        for p from pos <= p < new_pos:
            i = samples[p]

            if sample_weight != NULL:
                w  = sample_weight[i]

            for k from 0 <= k < n_outputs:
                y_ik = y[i * y_stride + k]
                w_y_ik = w * y_ik

                sq_sum_left[k] += w_y_ik * y_ik
                sq_sum_right[k] -= w_y_ik * y_ik

                mean_left[k] = ((weighted_n_left * mean_left[k] + w_y_ik) /
                                (weighted_n_left + w))
                mean_right[k] = ((weighted_n_right * mean_right[k] - w_y_ik) /
                                 (weighted_n_right - w))

            weighted_n_left += w
            weighted_n_right -= w

        for k from 0 <= k < n_outputs:
            var_left[k] = (sq_sum_left[k] -
                           weighted_n_left * (mean_left[k] * mean_left[k]))
            var_right[k] = (sq_sum_right[k] -
                            weighted_n_right * (mean_right[k] * mean_right[k]))

        self.weighted_n_left = weighted_n_left
        self.weighted_n_right = weighted_n_right

        self.pos = new_pos

    cdef double node_impurity(self) nogil:
        pass

    cdef double children_impurity(self) nogil:
        pass

    cdef void node_value(self, double* dest) nogil:
        """Compute the node value of samples[start:end] into dest."""
        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* mean_total = self.mean_total
        cdef SIZE_t k

        for k from 0 <= k < n_outputs:
            dest[k] = mean_total[k]

cdef class MSE(RegressionCriterion):
    """Mean squared error impurity criterion.

        MSE = var_left + var_right
    """
    cdef double node_impurity(self) nogil:
        """Evaluate the impurity of the current node, i.e. the impurity of
           samples[start:end]."""
        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* sq_sum_total = self.sq_sum_total
        cdef double* mean_total = self.mean_total
        cdef double weighted_n_node_samples = self.weighted_n_node_samples
        cdef double total = 0.0
        cdef SIZE_t k

        for k from 0 <= k < n_outputs:
            total += (sq_sum_total[k] -
                      weighted_n_node_samples * (mean_total[k] *
                                                 mean_total[k]))

        return total / n_outputs

    cdef double children_impurity(self) nogil:
        """Evaluate the impurity in children nodes, i.e. the impurity of
           samples[start:pos] + the impurity of samples[pos:end]."""
        cdef SIZE_t n_outputs = self.n_outputs
        cdef double* var_left = self.var_left
        cdef double* var_right = self.var_right
        cdef double total = 0.0
        cdef SIZE_t k

        for k from 0 <= k < n_outputs:
            total += var_left[k]
            total += var_right[k]

        return total / n_outputs


# =============================================================================
# Splitter
# =============================================================================

cdef class Splitter:
    def __cinit__(self, Criterion criterion,
                        SIZE_t max_features,
                        SIZE_t min_samples_leaf,
                        object random_state):
        self.criterion = criterion

        self.samples = NULL
        self.n_samples = 0
        self.features = NULL
        self.n_features = 0

        self.X = None
        self.y = NULL
        self.y_stride = 0
        self.sample_weight = NULL

        self.max_features = max_features
        self.min_samples_leaf = min_samples_leaf
        self.random_state = random_state

    def __dealloc__(self):
        """Destructor."""
        free(self.samples)
        free(self.features)

    def __getstate__(self):
        return {}

    def __setstate__(self, d):
        pass

    cdef void init(self, np.ndarray[DTYPE_t, ndim=2, mode="c"] X,
                         np.ndarray[DOUBLE_t, ndim=2, mode="c"] y,
                         DOUBLE_t* sample_weight):
        """Initialize the splitter."""
        # Free old structures if any
        if self.samples != NULL:
            free(self.samples)
        if self.features != NULL:
            free(self.features)

        # Reset random state
        self.rand_r_state = self.random_state.randint(0, RAND_MAX)

        # Initialize samples and features structures
        cdef SIZE_t n_samples = X.shape[0]
        cdef SIZE_t* samples = <SIZE_t*> malloc(n_samples * sizeof(SIZE_t))

        cdef SIZE_t i, j
        j = 0

        for i from 0 <= i < n_samples:
            # Only work with positively weighted samples
            if sample_weight == NULL or sample_weight[i] != 0.0:
                samples[j] = i
                j += 1

        self.samples = samples
        self.n_samples = j

        cdef SIZE_t n_features = X.shape[1]
        cdef SIZE_t* features = <SIZE_t*> malloc(n_features * sizeof(SIZE_t))

        for i from 0 <= i < n_features:
            features[i] = i

        self.features = features
        self.n_features = n_features

        # Initialize X, y, sample_weight
        self.X = X
        self.y = <DOUBLE_t*> y.data
        self.y_stride = <SIZE_t> y.strides[0] / <SIZE_t> y.itemsize
        self.sample_weight = sample_weight

    cdef void node_reset(self, SIZE_t start, SIZE_t end, double* impurity):
        """Reset splitter on node samples[start:end]."""
        cdef Criterion criterion = self.criterion

        cdef SIZE_t* samples = self.samples
        self.start = start
        self.end = end

        criterion.init(self.y,
                       self.y_stride,
                       self.sample_weight,
                       samples,
                       start,
                       end)

        impurity[0] =  criterion.node_impurity()

    cdef void node_split(self, SIZE_t* pos, SIZE_t* feature, double* threshold):
        """Find a split on node samples[start:end]."""
        pass

    cdef void node_value(self, double* dest):
        """Copy the value of node samples[start:end] into dest."""
        self.criterion.node_value(dest)


cdef class BestSplitter(Splitter):
    """Splitter for finding the best split."""
    def __reduce__(self):
        return (BestSplitter, (self.criterion,
                               self.max_features,
                               self.min_samples_leaf,
                               self.random_state), self.__getstate__())

    cdef void node_split(self, SIZE_t* pos, SIZE_t* feature, double* threshold):
        """Find the best split on node samples[start:end]."""
        # Find the best split
        cdef Criterion criterion = self.criterion
        cdef SIZE_t* samples = self.samples
        cdef SIZE_t start = self.start
        cdef SIZE_t end = self.end

        cdef SIZE_t* features = self.features
        cdef SIZE_t n_features = self.n_features

        cdef np.ndarray[DTYPE_t, ndim=2, mode="c"] X = self.X
        cdef SIZE_t max_features = self.max_features
        cdef SIZE_t min_samples_leaf = self.min_samples_leaf
        cdef unsigned int* random_state = &self.rand_r_state

        cdef double best_impurity = INFINITY
        cdef SIZE_t best_pos = end
        cdef SIZE_t best_feature
        cdef double best_threshold

        cdef double current_impurity
        cdef SIZE_t current_pos
        cdef SIZE_t current_feature
        cdef double current_threshold

        cdef SIZE_t f_idx, f_i, f_j, p, tmp
        cdef SIZE_t visited_features = 0

        cdef SIZE_t partition_start
        cdef SIZE_t partition_end

        for f_idx from 0 <= f_idx < n_features:
            # Draw a feature at random
            f_i = n_features - f_idx - 1
            f_j = rand_int(n_features - f_idx, random_state)

            tmp = features[f_i]
            features[f_i] = features[f_j]
            features[f_j] = tmp

            current_feature = features[f_i]

            # Sort samples along that feature
            sort(X, current_feature, samples+start, end-start)

            # Evaluate all splits
            criterion.reset()
            p = start

            while p < end:
                while ((p + 1 < end) and
                       (X[samples[p + 1], current_feature] <= X[samples[p], current_feature] + 1.e-7)):
                    p += 1

                # p + 1 >= end or X[samples[p + 1], current_feature] > X[samples[p], current_feature]
                p += 1
                # p >= end or X[samples[p], current_feature] > X[samples[p - 1], current_feature]

                if p < end:
                    current_pos = p

                    # Reject if min_samples_leaf is not guaranteed
                    if (((current_pos - start) < min_samples_leaf) or
                        ((end - current_pos) < min_samples_leaf)):
                       continue

                    criterion.update(current_pos)
                    current_impurity = criterion.children_impurity()

                    if current_impurity < best_impurity:
                        best_impurity = current_impurity
                        best_pos = current_pos
                        best_feature = current_feature

                        current_threshold = (X[samples[p - 1], current_feature] + X[samples[p], current_feature]) / 2.0
                        if current_threshold == X[samples[p], current_feature]:
                            current_threshold = X[samples[p - 1], current_feature]

                        best_threshold = current_threshold

            if best_pos == end: # No valid split was ever found
                continue

            # Count one more visited feature
            visited_features += 1

            if visited_features >= max_features:
                break

        # Reorganize samples into samples[start:best_pos] + samples[best_pos:end]
        if best_pos < end:
            partition_start = start
            partition_end = end
            p = start

            while p < partition_end:
                if X[samples[p], best_feature] <= best_threshold:
                    p += 1

                else:
                    partition_end -= 1

                    tmp = samples[partition_end]
                    samples[partition_end] = samples[p]
                    samples[p] = tmp

        # Return values
        pos[0] = best_pos
        feature[0] = best_feature
        threshold[0] = best_threshold

cdef void sort(np.ndarray[DTYPE_t, ndim=2, mode="c"] X, SIZE_t current_feature,
               SIZE_t* samples, SIZE_t length):
    """In-place sorting of samples[start:end] using
      X[sample[i], current_feature] as key."""
    # Heapsort, adapted from Numerical Recipes in C
    cdef SIZE_t tmp
    cdef DOUBLE_t tmp_value
    cdef SIZE_t n = length
    cdef SIZE_t parent = length / 2
    cdef SIZE_t index, child

    while True:
        if parent > 0:
            parent -= 1
            tmp = samples[parent]
        else:
            n -= 1
            if n == 0:
                return
            tmp = samples[n]
            samples[n] = samples[0]

        tmp_value = X[tmp, current_feature]
        index = parent
        child = index * 2 + 1

        while child < n:
            if ((child + 1 < n) and
                (X[samples[child + 1], current_feature] > X[samples[child], current_feature])):
                child += 1

            if X[samples[child], current_feature] > tmp_value:
                samples[index] = samples[child]
                index = child
                child = index * 2 + 1

            else:
                break

        samples[index] = tmp


cdef class RandomSplitter(Splitter):
    """Splitter for finding the best random split."""
    def __reduce__(self):
        return (RandomSplitter, (self.criterion,
                                 self.max_features,
                                 self.min_samples_leaf,
                                 self.random_state), self.__getstate__())

    cdef void node_split(self, SIZE_t* pos, SIZE_t* feature, double* threshold):
        """Find the best random split on node samples[start:end]."""
        # Draw random splits and pick the best
        cdef Criterion criterion = self.criterion
        cdef SIZE_t* samples = self.samples
        cdef SIZE_t start = self.start
        cdef SIZE_t end = self.end

        cdef SIZE_t* features = self.features
        cdef SIZE_t n_features = self.n_features

        cdef np.ndarray[DTYPE_t, ndim=2, mode="c"] X = self.X
        cdef SIZE_t max_features = self.max_features
        cdef SIZE_t min_samples_leaf = self.min_samples_leaf
        cdef unsigned int* random_state = &self.rand_r_state

        cdef double best_impurity = INFINITY
        cdef SIZE_t best_pos = end
        cdef SIZE_t best_feature
        cdef double best_threshold

        cdef double current_impurity
        cdef SIZE_t current_pos
        cdef SIZE_t current_feature
        cdef double current_threshold

        cdef SIZE_t f_idx, f_i, f_j, p, tmp
        cdef SIZE_t visited_features = 0
        cdef DTYPE_t min_feature_value
        cdef DTYPE_t max_feature_value
        cdef DTYPE_t current_feature_value

        cdef SIZE_t partition_start
        cdef SIZE_t partition_end

        for f_idx from 0 <= f_idx < n_features:
            # Draw a feature at random
            f_i = n_features - f_idx - 1
            f_j = rand_int(n_features - f_idx, random_state)

            tmp = features[f_i]
            features[f_i] = features[f_j]
            features[f_j] = tmp

            current_feature = features[f_i]

            # Find min, max
            min_feature_value = max_feature_value = X[samples[start], current_feature]

            for p from start < p < end:
                current_feature_value = X[samples[p], current_feature]

                if current_feature_value < min_feature_value:
                    min_feature_value = current_feature_value
                elif current_feature_value > max_feature_value:
                    max_feature_value = current_feature_value

            if min_feature_value == max_feature_value:
                continue

            # Draw a random threshold
            current_threshold = (min_feature_value +
                                 rand_double(random_state) * (max_feature_value - min_feature_value))

            if current_threshold == max_feature_value:
                current_threshold = min_feature_value

            # Partition
            partition_start = start
            partition_end = end
            p = start

            while p < partition_end:
                if X[samples[p], current_feature] <= current_threshold:
                    p += 1

                else:
                    partition_end -= 1

                    tmp = samples[partition_end]
                    samples[partition_end] = samples[p]
                    samples[p] = tmp

            current_pos = partition_end

            # Reject if min_samples_leaf is not guaranteed
            if (((current_pos - start) < min_samples_leaf) or
                ((end - current_pos) < min_samples_leaf)):
               continue

            # Evaluate split
            criterion.reset()
            criterion.update(current_pos)
            current_impurity = criterion.children_impurity()

            if current_impurity < best_impurity:
                best_impurity = current_impurity
                best_pos = current_pos
                best_feature = current_feature
                best_threshold = current_threshold

            # Count one more visited feature
            visited_features += 1

            if visited_features >= max_features:
                break

        # Reorganize samples into samples[start:best_pos] + samples[best_pos:end]
        if best_pos < end and current_feature != best_feature:
            partition_start = start
            partition_end = end
            p = start

            while p < partition_end:
                if X[samples[p], best_feature] <= best_threshold:
                    p += 1

                else:
                    partition_end -= 1

                    tmp = samples[partition_end]
                    samples[partition_end] = samples[p]
                    samples[p] = tmp

        # Return values
        pos[0] = best_pos
        feature[0] = best_feature
        threshold[0] = best_threshold


# =============================================================================
# Storage
# =============================================================================
cdef class Storage:

    property nbytes:
        def __get__(self):
            # max_n_classes, value_stride, n_outputs, n_classes_
            nbytes = (3 + self.n_outputs) * sizeof(SIZE_t)
            nbytes += self.capacity_data * sizeof(double)
            return nbytes

    def __cinit__(self, Splitter splitter, SIZE_t n_outputs,
                  np.ndarray[SIZE_t, ndim=1] n_classes):

        self.splitter = splitter
        self.max_n_classes = np.max(n_classes)
        self.value_stride = self.max_n_classes * n_outputs
        self.n_outputs = n_outputs

        self.n_classes = <SIZE_t*> malloc(n_outputs * sizeof(SIZE_t))
        if self.n_classes == NULL:
            raise MemoryError()

        cdef SIZE_t k
        for k from 0 <= k < n_outputs:
            self.n_classes[k] = n_classes[k]

    def __dealloc__(self):
        """Destructor."""
        free(self.n_classes)
        free(self.data)

    def __reduce__(self):
        """Reduce re-implementation, for pickling."""
        return (Storage,
                (self.splitter,
                 self.n_outputs,
                 sizet_ptr_to_ndarray(self.n_classes, self.n_outputs)),
                self.__getstate__())

    def __getstate__(self):
        """Getstate re-implementation, for pickling."""
        d = {}
        d["capacity_data"] = self.capacity_data
        d["data"] = double_ptr_to_ndarray(self.data, self.capacity_data)
        return d

    def __setstate__(self, d):
        """Setstate re-implementation, for unpickling."""
        # NB capacity data must be handle by the subclass
        self.resize_data(d["capacity_data"])
        self.capacity_data = d["capacity_data"]

        cdef double* data = <double*> (<np.ndarray> d["data"]).data
        memcpy(self.data, data, self.capacity_data * sizeof(double))

    # Methods
    cdef void resize_data(self, SIZE_t capacity_data):
        """Resize data to capacity_data, if capacity_data <= 0, size is double
        """
        if capacity_data == self.capacity_data:
            return

        if capacity_data < 0:
            if self.capacity_data <= 0:
                # default initial value
                capacity_data = max(self.value_stride, 2048)
            else:
                capacity_data = 2 * self.capacity_data

        cdef double* tmp_data = <double*> realloc(self.data, capacity_data  * sizeof(double))
        if tmp_data != NULL:
            self.data = tmp_data

        if ((tmp_data == NULL)):
            raise MemoryError()

        self.capacity_data = capacity_data


    cdef void resize(self, SIZE_t capacity):
        """Resize storage to at capacity node"""
        pass

    cdef void add_node(self, SIZE_t node_id):
        """Ad the node value in storage with id set to node_ids"""
        pass

    cdef np.ndarray node_value(self, SIZE_t* node_ids, SIZE_t n_samples):
        """Get node values for given node_ids"""
        pass

    cdef np.ndarray toarray(self):
        """Transform stored values into an array"""
        pass


cdef class FlatStorage(Storage):
    """ Flat storage - no memory optimization
    """

    def __reduce__(self):
        """Reduce re-implementation, for pickling."""
        return (FlatStorage,
                (self.splitter,
                 self.n_outputs,
                 sizet_ptr_to_ndarray(self.n_classes, self.n_outputs)),
                self.__getstate__())

    cdef void resize(self, SIZE_t capacity):
        """Resize storage to at capacity node"""
        self.resize_data(capacity * self.value_stride)

    cdef void add_node(self, SIZE_t node_id):
        """Ad the node value in storage with id set to node_ids"""
        self.splitter.node_value(self.data + node_id * self.value_stride)

    cdef np.ndarray node_value(self, SIZE_t* node_ids, SIZE_t n_samples):
        """Get node values for given node_ids"""

        cdef SIZE_t* n_classes = self.n_classes
        cdef double* data = self.data

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t max_n_classes = self.max_n_classes
        cdef SIZE_t value_stride = self.value_stride

        cdef SIZE_t i
        cdef SIZE_t k
        cdef SIZE_t c

        cdef np.ndarray[np.float64_t, ndim=2] out
        cdef np.ndarray[np.float64_t, ndim=3] out_multi

        if self.n_outputs == 1:
            out = np.zeros((n_samples, max_n_classes), dtype=np.float64)

            for i from 0 <= i < n_samples:
                offset = node_ids[i] * value_stride

                for c from 0 <= c < n_classes[0]:
                    out[i, c] = data[offset + c]

            return out

        else: # n_outputs > 1
            out_multi = np.zeros((n_samples,
                                  n_outputs,
                                  max_n_classes), dtype=np.float64)

            for i from 0 <= i < n_samples:
                offset = node_ids[i] * value_stride

                for k from 0 <= k < n_outputs:
                    for c from 0 <= c < n_classes[k]:
                        out_multi[i, k, c] = data[offset + c]
                    offset += max_n_classes

            return out_multi

    cdef np.ndarray toarray(self):
        """Transform stored values into an array"""
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t max_n_classes = self.max_n_classes
        cdef SIZE_t value_stride = self.value_stride

        cdef double* data = self.data
        cdef SIZE_t capacity = self.capacity_data / self.value_stride

        cdef np.ndarray[np.float64_t, ndim=3] out
        out = np.zeros((capacity, n_outputs, max_n_classes),
                       dtype=np.float64)

        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t i
        cdef offset = 0

        for i from 0 <= i < capacity:
            for k from 0 <= k < n_outputs:
                for c from 0 <= c < n_classes[k]:
                    out[i, k, c] = data[offset + c]
                offset += max_n_classes

        return out


cdef class CompressedStorage(Storage):

    cdef SIZE_t* node_index # Negative number indicates dense storage,
                            # Positive number indicates sparse storage
                            # 0 means undefined value

    cdef SIZE_t capacity_node
    cdef SIZE_t count_sparse_node
    cdef SIZE_t count_dense_node
    cdef SIZE_t count_node

    # CSR datastructure
    cdef SIZE_t capacity_data_sparse
    cdef SIZE_t capacity_indptr

    cdef SIZE_t* indptr
    cdef SIZE_t* indices
    cdef double* data_sparse

    # Dense datastructure
    # cdef SIZE_t capacity_data
    # cdef double* data

    property nbytes:
        def __get__(self):
            raise NotImplementedError()

    def __cinit__(self, Splitter splitter, SIZE_t n_outputs,
                  np.ndarray[SIZE_t, ndim=1] n_classes):

        self.indptr = <SIZE_t*> malloc(2 * sizeof(SIZE_t))
        self.indptr[0] = 0
        self.indptr[1] = 0

    def __dealloc__(self):
        """Destructor."""
        free(self.data_sparse)
        free(self.indices)
        free(self.indptr)
        free(self.node_index)

    def __reduce__(self):
        """Reduce re-implementation, for pickling."""
        return (CompressedStorage,
                (self.splitter,
                 self.n_outputs,
                 sizet_ptr_to_ndarray(self.n_classes, self.n_outputs)),
                self.__getstate__())

    def __getstate__(self):
        """Getstate re-implementation, for pickling."""
        d = super(CompressedStorage, self).__getstate__()

        # Index structure
        d["node_index"] = sizet_ptr_to_ndarray(self.node_index,  self.capacity_node)
        d["capacity_node"] = self.capacity_node
        d["count_node"] = self.count_node
        d["count_sparse_node"] = self.count_sparse_node
        d["count_dense_node"] = self.count_dense_node

        # CSR datastructure
        d["capacity_data_sparse"] = self.capacity_data_sparse
        d["capacity_indptr"] = self.capacity_indptr

        d["indptr"] = sizet_ptr_to_ndarray(self.indptr, self.capacity_indptr)
        d["indices"] = sizet_ptr_to_ndarray(self.indices, self.capacity_data_sparse)
        d["data_sparse"] = double_ptr_to_ndarray(self.data_sparse, self.capacity_data_sparse)

        return d

    def __setstate__(self, d):
        """Setstate re-implementation, for unpickling."""
        super(CompressedStorage, self).__setstate__(d)

        self.resize_data_sparse(d["capacity_data_sparse"]) # Sparse node
        self.resize(d["capacity"]) # index structure

        # Node index structure
        self.capacity_node = d["capacity_node"]
        self.count_node = d["count_node"]
        self.count_sparse_node = d["count_sparse_node"]
        self.count_dense_node = d["count_dense_node"]

        cdef SIZE_t* node_index = <SIZE_t*> (<np.ndarray> d["node_index"]).data
        memcpy(self.node_index, node_index, self.capacity_node * sizeof(SIZE_t))

        # Sparse datastructure
        cdef SIZE_t* indptr = <SIZE_t*> (<np.ndarray> d["indptr"]).data
        memcpy(self.indptr, indptr, self.capacity_indptr * sizeof(SIZE_t))

        cdef SIZE_t* indices = <SIZE_t*> (<np.ndarray> d["indices"]).data
        memcpy(self.indices, indices, self.capacity_data_sparse * sizeof(SIZE_t))

        cdef double* data_sparse = <double*> (<np.ndarray> d["data_sparse"]).data
        memcpy(self.data_sparse, data_sparse, self.capacity_data_sparse * sizeof(double))

    # Methods
    cdef void resize_data_sparse(self, SIZE_t capacity_data_sparse):
        """Resize  the data spare and indices vector of the sparse storage"""
        if capacity_data_sparse == self.capacity_data_sparse:
            return

        if capacity_data_sparse < 0:
            if self.capacity_data_sparse <= 0:
                # default initial value
                capacity_data_sparse = max(2048, 10 * self.value_stride)
            else:
                capacity_data_sparse = 2 * self.capacity_data_sparse

        self.capacity_data_sparse = capacity_data_sparse

        cdef SIZE_t* tmp_indices = <SIZE_t*> realloc(self.indices, capacity_data_sparse * sizeof(SIZE_t))
        if tmp_indices != NULL:
            self.indices = tmp_indices

        cdef double* tmp_data_sparse = <double*> realloc(self.data_sparse, capacity_data_sparse * sizeof(double))
        if tmp_data_sparse != NULL:
            self.data_sparse = tmp_data_sparse

        if ((tmp_indices == NULL) or
            (tmp_data_sparse == NULL)):
            raise MemoryError()


    cdef void resize_indptr(self, SIZE_t capacity_indptr):
        """Resize the indptr array"""
        # We need at least + 1 value for the last index
        capacity_indptr = capacity_indptr + 1

        if capacity_indptr == self.capacity_indptr:
            return

        if capacity_indptr < 0:
            if self.capacity_indptr <= 0:
                # default initial value
                capacity_indptr = 2048
            else:
                capacity_indptr = 2 * self.capacity_indptr

        cdef SIZE_t* tmp_indptr = <SIZE_t*> realloc(self.indptr, capacity_indptr * sizeof(SIZE_t))
        if tmp_indptr != NULL:
            self.indptr = tmp_indptr

        if ((tmp_indptr == NULL)):
            raise MemoryError()

        self.capacity_indptr = capacity_indptr

    cdef void resize(self, SIZE_t capacity):
        """Resize storage the node index array"""

        if capacity <= self.capacity_node:
            self.resize_indptr(self.count_sparse_node)
            self.resize_data_sparse(self.indptr[self.count_sparse_node + 1])
            self.resize_data(self.count_dense_node)
            return

        if capacity < 0:
            if self.capacity_node <= 0:
                # default initial value
                capacity = 2048
            else:
                capacity = 2 * self.capacity_node

        cdef SIZE_t* tmp_node_index = <SIZE_t*> realloc(self.node_index, self.capacity_node * sizeof(double*))
        if tmp_node_index != NULL:
            self.node_index = tmp_node_index

        cdef SIZE_t i
        for i from self.count_node <= i < capacity:
            tmp_node_index[i] = 0

        # Wee need always one more value for last ptr
        self.capacity_node = capacity

    cdef void add_node(self, SIZE_t node_id):
        """Ad the node value in storage with id set to node_ids

        Warning: assume that added nodes are always increasing
        """
        cdef SIZE_t value_stride = self.value_stride
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t max_n_classes = self.max_n_classes

        cdef bint is_sparse
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t n
        cdef SIZE_t offset
        cdef SIZE_t counter
        cdef SIZE_t index

        # Node index structure
        if self.capacity_node < node_id:
            self.resize(2 * node_id)
        cdef SIZE_t* node_index = self.node_index

        # Dense datastructure
        if (self.count_dense_node + 1) * value_stride >= self.capacity_data:
            self.resize_data(-1)

        cdef double* data = self.data

        # The buffer is the end of the data array
        cdef double* data_buffer = data + self.count_dense_node * value_stride

        # CSR datastructure
        if self.count_sparse_node + 1 >= self.capacity_indptr:
            self.resize_indptr(-1)

        cdef SIZE_t* indptr = self.indptr

        if (indptr[self.count_sparse_node] + value_stride
                >= self.capacity_data_sparse):
            self.resize_data_sparse(-1)

        cdef SIZE_t* indices = self.indices
        cdef double* data_sparse = self.data_sparse


        self.splitter.node_value(data_buffer)

        # Determine sparsity
        is_sparse = False
        if self.max_n_classes > 2:
            counter = 0
            offset = 0
            for k from 0 <= k < n_outputs:
                for c from 0 <= c < n_classes[k]:
                    if data_buffer[offset + c] != 0.:
                        counter += 1
                offset += max_n_classes

            if 2 * counter < value_stride:
                is_sparse = True

        # Get the index
        if is_sparse:
            index = self.count_sparse_node + 1
            self.count_sparse_node += 1

        else:
            index = - self.count_dense_node - 1 # We don't want to have zero
            self.count_dense_node += 1

        node_index[node_id] = index

        # Store node value
        if is_sparse:
            offset = 0
            index = node_index[node_id] - 1 # Get the index value in the sparse storage
            offset_indptr = indptr[index]
            for k from 0 <= k < n_outputs:
                for c from 0 <= c < n_classes[k]:
                    if data_buffer[offset + c] != 0.:
                        data[offset_indptr] = data_buffer[offset + c]
                        indices[offset_indptr] = offset + c
                        offset_indptr += 1

                offset += max_n_classes
            indptr[index + 1] = offset_indptr
        # else: # dense value is already there thanks to the buffer

        if node_id > self.count_node:
            self.count_node = node_id + 1

    cdef np.ndarray node_value(self, SIZE_t* node_ids, SIZE_t n_samples):
        """Get node values for given node_ids"""
        cdef SIZE_t value_stride = self.value_stride
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t max_n_classes = self.max_n_classes

        cdef SIZE_t* node_index = self.node_index

        # CSR datastructure
        cdef SIZE_t* indptr = self.indptr
        cdef SIZE_t* indices = self.indices
        cdef double* data_sparse = self.data_sparse

        # Dense datastructure
        cdef double* data = self.data

        cdef SIZE_t i
        cdef SIZE_t k
        cdef SIZE_t c
        cdef SIZE_t j
        cdef SIZE_t offset
        cdef SIZE_t index

        cdef np.ndarray[np.float64_t, ndim=2] out
        cdef np.ndarray[np.float64_t, ndim=3] out_multi

        if self.n_outputs == 1:
            out = np.zeros((n_samples, max_n_classes), dtype=np.float64)

            for i from 0 <= i < n_samples:
                index = node_index[node_ids[i]]

                if index < 0: # Dense node
                    offset = (- index - 1) * value_stride
                    for j from 0 <= j < n_classes[0]:
                        out[i, j] = data[offset + j]

                elif index > 0:  # Sparse node
                    index -= 1
                    for j from indptr[index] <= j < indptr[index + 1]:
                        c = indices[j]
                        out[i, c] = data[j]
                else:
                    raise ValueError("Undefined node")

            return out

        else: # n_outputs > 1
            out_multi = np.zeros((n_samples, n_outputs, max_n_classes),
                                 dtype=np.float64)

            for i from 0 <= i < n_samples:
                index = node_index[node_ids[i]]

                if index < 0: # Dense node
                    offset = (- index - 1) * value_stride
                    for k from 0 <= k < n_outputs:
                        for c from 0 <= c < n_classes[k]:
                            out_multi[i, k, c] = data[offset + c]
                        offset += max_n_classes

                elif index > 0:  # Sparse node
                    index -= 1
                    for j from indptr[index] <= j < indptr[index + 1]:
                        c = indices[j] % max_n_classes
                        k = indices[j] / max_n_classes
                        out_multi[i, k, c] = data[j]
                else:
                    raise ValueError("Undefined node")

            return out_multi

    cdef np.ndarray toarray(self):
        """Transform stored values into an array"""

        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t max_n_classes = self.max_n_classes
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t value_stride = self.value_stride


        cdef SIZE_t* node_index = self.node_index
        cdef SIZE_t count_node = self.count_node

        # CSR datastructure
        cdef SIZE_t* indptr = self.indptr
        cdef SIZE_t* indices = self.indices
        cdef double* data_sparse = self.data_sparse

        # Dense datastructure
        cdef double* data = self.data

        cdef SIZE_t i
        cdef SIZE_t k
        cdef SIZE_t j
        cdef SIZE_t offset
        cdef SIZE_t index

        cdef np.ndarray[np.float64_t, ndim=3] out
        out = np.zeros((count_node, n_outputs,
                        max_n_classes), dtype=np.float64)

        print(sizet_ptr_to_ndarray(node_index, count_node))

        for i from 0 <= i < count_node:
            index = node_index[i]

            if index == 0: # internal nodes
                continue

            if index < 0:  # Dense node
                offset = (- index - 1) * value_stride
                for k from 0 <= k < n_outputs:
                    for c from 0 <= c < n_classes[k]:
                        out[i, k, c] = data[offset + c]
                    offset += max_n_classes

            else:  # Sparse node
                index -= 1
                for j from indptr[index] <= j < indptr[index + 1]:
                    c = indices[j] % max_n_classes
                    k = indices[j] / max_n_classes
                    out[i, k, c] = data[j]

        return out

# =============================================================================
# Tree
# =============================================================================

cdef class Tree:
    # Wrap for outside world
    property n_classes:
        def __get__(self):
            return sizet_ptr_to_ndarray(self.n_classes, self.n_outputs)

    property children_left:
        def __get__(self):
            return sizet_ptr_to_ndarray(self.children_left, self.node_count)

    property children_right:
        def __get__(self):
            return sizet_ptr_to_ndarray(self.children_right, self.node_count)

    property feature:
        def __get__(self):
            return sizet_ptr_to_ndarray(self.feature, self.node_count)

    property threshold:
        def __get__(self):
            return double_ptr_to_ndarray(self.threshold, self.node_count)

    property value:
        def __get__(self):
            return self.storage.toarray()

    property impurity:
        def __get__(self):
            return double_ptr_to_ndarray(self.impurity, self.node_count)

    property n_node_samples:
        def __get__(self):
            return sizet_ptr_to_ndarray(self.n_node_samples, self.node_count)

    def __cinit__(self, int n_features, np.ndarray[SIZE_t, ndim=1] n_classes,
                        int n_outputs, Splitter splitter,
                        Storage storage, SIZE_t max_depth,
                        SIZE_t min_samples_split, SIZE_t min_samples_leaf,
                        object random_state):
        """Constructor."""
        # Input/Output layout
        self.n_features = n_features
        self.n_outputs = n_outputs
        self.n_classes = <SIZE_t*> malloc(n_outputs * sizeof(SIZE_t))

        if self.n_classes == NULL:
            raise MemoryError()

        self.max_n_classes = np.max(n_classes)
        self.value_stride = self.n_outputs * self.max_n_classes

        cdef SIZE_t k

        for k from 0 <= k < n_outputs:
            self.n_classes[k] = n_classes[k]

        # Parameters
        self.splitter = splitter
        self.max_depth = max_depth
        self.min_samples_split = min_samples_split
        self.min_samples_leaf = min_samples_leaf
        self.random_state = random_state
        self.storage = storage

        # Inner structures
        self.node_count = 0
        self.capacity = 0
        self.children_left = NULL
        self.children_right = NULL
        self.feature = NULL
        self.threshold = NULL
        self.impurity = NULL
        self.n_node_samples = NULL

    def __dealloc__(self):
        """Destructor."""
        # Free all inner structures
        free(self.n_classes)
        free(self.children_left)
        free(self.children_right)
        free(self.feature)
        free(self.threshold)
        free(self.impurity)
        free(self.n_node_samples)

    def __reduce__(self):
        """Reduce re-implementation, for pickling."""
        return (Tree, (self.n_features,
                       sizet_ptr_to_ndarray(self.n_classes, self.n_outputs),
                       self.n_outputs,
                       self.splitter,
                       self.storage,
                       self.max_depth,
                       self.min_samples_split,
                       self.min_samples_leaf,
                       self.random_state), self.__getstate__())

    def __getstate__(self):
        """Getstate re-implementation, for pickling."""
        d = {}

        d["node_count"] = self.node_count
        d["capacity"] = self.capacity
        d["children_left"] = sizet_ptr_to_ndarray(self.children_left, self.capacity)
        d["children_right"] = sizet_ptr_to_ndarray(self.children_right, self.capacity)
        d["feature"] = sizet_ptr_to_ndarray(self.feature, self.capacity)
        d["threshold"] = double_ptr_to_ndarray(self.threshold, self.capacity)
        d["impurity"] = double_ptr_to_ndarray(self.impurity, self.capacity)
        d["n_node_samples"] = sizet_ptr_to_ndarray(self.n_node_samples, self.capacity)

        return d

    def __setstate__(self, d):
        """Setstate re-implementation, for unpickling."""
        self._resize(d["capacity"])
        self.node_count = d["node_count"]

        cdef SIZE_t* children_left = <SIZE_t*> (<np.ndarray> d["children_left"]).data
        cdef SIZE_t* children_right =  <SIZE_t*> (<np.ndarray> d["children_right"]).data
        cdef SIZE_t* feature = <SIZE_t*> (<np.ndarray> d["feature"]).data
        cdef double* threshold = <double*> (<np.ndarray> d["threshold"]).data
        cdef double* impurity = <double*> (<np.ndarray> d["impurity"]).data
        cdef SIZE_t* n_node_samples = <SIZE_t*> (<np.ndarray> d["n_node_samples"]).data

        memcpy(self.children_left, children_left, self.capacity * sizeof(SIZE_t))
        memcpy(self.children_right, children_right, self.capacity * sizeof(SIZE_t))
        memcpy(self.feature, feature, self.capacity * sizeof(SIZE_t))
        memcpy(self.threshold, threshold, self.capacity * sizeof(double))
        memcpy(self.impurity, impurity, self.capacity * sizeof(double))
        memcpy(self.n_node_samples, n_node_samples, self.capacity * sizeof(SIZE_t))

    cdef void _resize(self, int capacity=-1):
        """Resize all inner arrays to `capacity`, if `capacity` < 0, then
           double the size of the inner arrays."""
        if capacity == self.capacity:
            return

        if capacity < 0:
            if self.capacity <= 0:
                capacity = 3 # default initial value
            else:
                capacity = 2 * self.capacity

        self.capacity = capacity

        cdef SIZE_t* tmp_children_left = <SIZE_t*> realloc(self.children_left, capacity * sizeof(SIZE_t))
        if tmp_children_left != NULL:
            self.children_left = tmp_children_left

        cdef SIZE_t* tmp_children_right = <SIZE_t*> realloc(self.children_right, capacity * sizeof(SIZE_t))
        if tmp_children_right != NULL:
            self.children_right = tmp_children_right

        cdef SIZE_t* tmp_feature = <SIZE_t*> realloc(self.feature, capacity * sizeof(SIZE_t))
        if tmp_feature != NULL:
            self.feature = tmp_feature

        cdef double* tmp_threshold = <double*> realloc(self.threshold, capacity * sizeof(double))
        if tmp_threshold != NULL:
            self.threshold = tmp_threshold

        cdef double* tmp_impurity = <double*> realloc(self.impurity, capacity * sizeof(double))
        if tmp_impurity != NULL:
            self.impurity = tmp_impurity

        cdef SIZE_t* tmp_n_node_samples = <SIZE_t*> realloc(self.n_node_samples, capacity * sizeof(SIZE_t))
        if tmp_n_node_samples != NULL:
            self.n_node_samples = tmp_n_node_samples

        if ((tmp_children_left == NULL) or
            (tmp_children_right == NULL) or
            (tmp_feature == NULL) or
            (tmp_threshold == NULL) or
            (tmp_impurity == NULL) or
            (tmp_n_node_samples == NULL)):
            raise MemoryError()

        self.storage.resize(capacity)

        # if capacity smaller than node_count, adjust the counter
        if capacity < self.node_count:
            self.node_count = capacity

    cdef SIZE_t _add_node(self, SIZE_t parent,
                                bint is_left,
                                bint is_leaf,
                                SIZE_t feature,
                                double threshold,
                                double impurity,
                                SIZE_t n_node_samples):
        """Add a node to the tree. The new node registers itself as
           the child of its parent. """
        cdef SIZE_t node_id = self.node_count

        if node_id >= self.capacity:
            self._resize()

        self.impurity[node_id] = impurity
        self.n_node_samples[node_id] = n_node_samples

        if parent != _TREE_UNDEFINED:
            if is_left:
                self.children_left[parent] = node_id
            else:
                self.children_right[parent] = node_id

        if not is_leaf:
            # children_left and children_right will be set later
            self.feature[node_id] = feature
            self.threshold[node_id] = threshold

        else:
            self.children_left[node_id] = _TREE_LEAF
            self.children_right[node_id] = _TREE_LEAF
            self.feature[node_id] = _TREE_UNDEFINED
            self.threshold[node_id] = _TREE_UNDEFINED

        self.node_count += 1

        return node_id

    cpdef build(self, np.ndarray X,
                      np.ndarray y,
                      np.ndarray sample_weight=None):
        """Build a decision tree from the training set (X, y)."""
        # Prepare data before recursive partitioning
        if X.dtype != DTYPE or not X.flags.contiguous:
            X = np.asarray(X, dtype=DTYPE, order="C")

        if y.dtype != DOUBLE or not y.flags.contiguous:
            y = np.asarray(y, dtype=DOUBLE, order="C")

        cdef DOUBLE_t* sample_weight_ptr = NULL
        if sample_weight is not None:
            if ((sample_weight.dtype != DOUBLE) or
                (not sample_weight.flags.contiguous)):
                sample_weight = np.asarray(sample_weight,
                                           dtype=DOUBLE, order="C")
            sample_weight_ptr = <DOUBLE_t*> sample_weight.data

        # Initial capacity
        cdef int init_capacity

        if self.max_depth <= 10:
            init_capacity = (2 ** (self.max_depth + 1)) - 1
        else:
            init_capacity = 2047

        self._resize(init_capacity)

        # Recursive partition (without actual recursion)
        cdef Splitter splitter = self.splitter
        cdef Storage storage = self.storage
        splitter.init(X, y, sample_weight_ptr)

        cdef SIZE_t stack_n_values = 5
        cdef SIZE_t stack_capacity = 50
        cdef SIZE_t* stack = <SIZE_t*> malloc(stack_capacity * sizeof(SIZE_t))

        stack[0] = 0                    # start
        stack[1] = splitter.n_samples   # end
        stack[2] = 0                    # depth
        stack[3] = _TREE_UNDEFINED      # parent
        stack[4] = 0                    # is_left

        cdef SIZE_t start
        cdef SIZE_t end
        cdef SIZE_t depth
        cdef SIZE_t parent
        cdef bint is_left

        cdef SIZE_t n_node_samples
        cdef SIZE_t pos
        cdef SIZE_t feature
        cdef double threshold
        cdef double impurity
        cdef bint is_leaf

        cdef SIZE_t node_id

        while stack_n_values > 0:
            stack_n_values -= 5

            start = stack[stack_n_values]
            end = stack[stack_n_values + 1]
            depth = stack[stack_n_values + 2]
            parent = stack[stack_n_values + 3]
            is_left = stack[stack_n_values + 4]

            n_node_samples = end - start
            is_leaf = ((depth >= self.max_depth) or
                       (n_node_samples < self.min_samples_split) or
                       (n_node_samples < 2 * self.min_samples_leaf))

            splitter.node_reset(start, end, &impurity)
            is_leaf = is_leaf or (impurity == 0.0)

            if not is_leaf:
                splitter.node_split(&pos, &feature, &threshold)
                is_leaf = is_leaf or (pos >= end)

            node_id = self._add_node(parent, is_left, is_leaf, feature,
                                     threshold, impurity, n_node_samples)

            if is_leaf:
                # Don't store value for internal nodes
                storage.add_node(node_id)

            else:
                if stack_n_values + 10 > stack_capacity:
                    stack_capacity *= 2
                    stack = <SIZE_t*> realloc(stack, stack_capacity * sizeof(SIZE_t))

                # Stack right child
                stack[stack_n_values] = pos
                stack[stack_n_values + 1] = end
                stack[stack_n_values + 2] = depth + 1
                stack[stack_n_values + 3] = node_id
                stack[stack_n_values + 4] = 0
                stack_n_values += 5

                # Stack left child
                stack[stack_n_values] = start
                stack[stack_n_values + 1] = pos
                stack[stack_n_values + 2] = depth + 1
                stack[stack_n_values + 3] = node_id
                stack[stack_n_values + 4] = 1
                stack_n_values += 5

        self._resize(self.node_count)
        free(stack)

    cpdef predict(self, np.ndarray[DTYPE_t, ndim=2] X):
        """Predict target for X."""
        cdef SIZE_t* children_left = self.children_left
        cdef SIZE_t* children_right = self.children_right
        cdef SIZE_t* feature = self.feature
        cdef double* threshold = self.threshold
        cdef Storage storage = self.storage

        cdef SIZE_t n_samples = X.shape[0]
        cdef SIZE_t* n_classes = self.n_classes
        cdef SIZE_t n_outputs = self.n_outputs
        cdef SIZE_t max_n_classes = self.max_n_classes
        cdef SIZE_t value_stride = self.value_stride

        cdef SIZE_t node_id = 0
        cdef SIZE_t offset
        cdef SIZE_t i
        cdef SIZE_t k
        cdef SIZE_t c

        cdef np.ndarray[np.float64_t, ndim=2] out
        cdef np.ndarray[np.float64_t, ndim=3] out_multi

        cdef SIZE_t* node_ids = <SIZE_t*> malloc(n_samples * sizeof(SIZE_t))

        for i from 0 <= i < n_samples:
            # While node_id not a leaf
            node_id = 0
            while children_left[node_id] != _TREE_LEAF:
                # ... and children_right[node_id] != _TREE_LEAF:
                if X[i, feature[node_id]] <= threshold[node_id]:
                    node_id = children_left[node_id]
                else:
                    node_id = children_right[node_id]
            node_ids[i] = node_id


        if n_outputs == 1:
            out = storage.node_value(node_ids, n_samples)
            free(node_ids)
            return out
        else:
            out_multi = storage.node_value(node_ids, n_samples)
            free(node_ids)
            return out_multi

    cpdef apply(self, np.ndarray[DTYPE_t, ndim=2] X):
        """Finds the terminal region (=leaf node) for each sample in X."""
        cdef SIZE_t* children_left = self.children_left
        cdef SIZE_t* children_right = self.children_right
        cdef SIZE_t* feature = self.feature
        cdef double* threshold = self.threshold

        cdef SIZE_t n_samples = X.shape[0]
        cdef SIZE_t node_id = 0
        cdef SIZE_t i = 0

        cdef np.ndarray[np.int32_t, ndim=1] out
        out = np.zeros((n_samples,), dtype=np.int32)

        for i from 0 <= i < n_samples:
            node_id = 0

            # While node_id not a leaf
            while children_left[node_id] != _TREE_LEAF:
                # ... and children_right[node_id] != _TREE_LEAF:
                if X[i, feature[node_id]] <= threshold[node_id]:
                    node_id = children_left[node_id]
                else:
                    node_id = children_right[node_id]

            out[i] = node_id

        return out

    cpdef compute_feature_importances(self, normalize=True):
        """Computes the importance of each feature (aka variable)."""
        cdef SIZE_t* children_left = self.children_left
        cdef SIZE_t* children_right = self.children_right
        cdef SIZE_t* feature = self.feature
        cdef double* impurity = self.impurity
        cdef SIZE_t* n_node_samples = self.n_node_samples

        cdef SIZE_t n_features = self.n_features
        cdef SIZE_t node_count = self.node_count

        cdef SIZE_t n_left
        cdef SIZE_t n_right
        cdef SIZE_t node

        cdef np.ndarray[np.float64_t, ndim=1] importances
        importances = np.zeros((self.n_features,))

        for node from 0 <= node < node_count:
            if children_left[node] != _TREE_LEAF:
                # ... and children_right[node] != _TREE_LEAF:
                n_left = n_node_samples[children_left[node]]
                n_right = n_node_samples[children_right[node]]

                importances[feature[node]] += \
                    n_node_samples[node] * impurity[node] \
                        - n_left * impurity[children_left[node]] \
                        - n_right * impurity[children_right[node]]

        importances = importances / self.n_node_samples[0]
        cdef double normalizer

        if normalize:
            normalizer = np.sum(importances)

            if normalizer > 0.0:
                # Avoid dividing by zero (e.g., when root is pure)
                importances /= normalizer

        return importances


# =============================================================================
# Utils
# =============================================================================

cdef inline np.ndarray int_ptr_to_ndarray(int* data, SIZE_t size):
    """Encapsulate data into a 1D numpy array of int's."""
    cdef np.npy_intp shape[1]
    shape[0] = <np.npy_intp> size
    return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT, data)

cdef inline np.ndarray sizet_ptr_to_ndarray(SIZE_t* data, SIZE_t size):
    """Encapsulate data into a 1D numpy array of intp's."""
    cdef np.npy_intp shape[1]
    shape[0] = <np.npy_intp> size
    return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INTP, data)

cdef inline np.ndarray double_ptr_to_ndarray(double* data, SIZE_t size):
    """Encapsulate data into a 1D numpy array of double's."""
    cdef np.npy_intp shape[1]
    shape[0] = <np.npy_intp> size
    return np.PyArray_SimpleNewFromData(1, shape, np.NPY_DOUBLE, data)

cdef inline SIZE_t rand_int(SIZE_t end, unsigned int* random_state):
    """Generate a random integer in [0; end)."""
    return sklearn_rand_r(random_state) % end

cdef inline double rand_double(unsigned int* random_state):
    """Generate a random double in [0; 1)."""
    return <double> sklearn_rand_r(random_state) / <double> RAND_MAX
