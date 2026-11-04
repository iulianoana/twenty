import { inspect } from 'util';

import { msg } from '@lingui/core/macro';
import { isDate, isNull, isString } from '@sniptt/guards';
import { format, isValid, parse } from 'date-fns';
import { ACCEPTED_DATE_FORMATS } from 'twenty-shared/utils';

import {
  CommonQueryRunnerException,
  CommonQueryRunnerExceptionCode,
} from 'src/engine/api/common/common-query-runners/errors/common-query-runner.exception';

// Postgres reads ambiguous strings like 03/11/2026 with its own DateStyle, so store ISO dates only
const DATE_FIELD_STORAGE_FORMAT = 'yyyy-MM-dd';

const parseDateInput = (value: string): Date | null => {
  for (const acceptedFormat of ACCEPTED_DATE_FORMATS) {
    const parsed = parse(value, acceptedFormat, new Date());

    if (isValid(parsed)) {
      return parsed;
    }
  }

  return null;
};

export const validateDateFieldOrThrow = (
  value: unknown,
  fieldName: string,
): unknown => {
  if (isNull(value)) return null;

  if (isDate(value) && isValid(value)) {
    return value;
  }

  if (isString(value)) {
    const parsedDate = parseDateInput(value);

    // Dates before 1970 come from broken spreadsheet exports (serial numbers read as dates)
    if (parsedDate !== null && parsedDate.getTime() >= 0) {
      return format(parsedDate, DATE_FIELD_STORAGE_FORMAT);
    }
  }

  const inspectedValue = inspect(value);

  throw new CommonQueryRunnerException(
    `Invalid value ${inspectedValue} for date field "${fieldName}". Expected format: 'YYYY-MM-DD'`,
    CommonQueryRunnerExceptionCode.INVALID_ARGS_DATA,
    {
      userFriendlyMessage: msg`Invalid value for date: "${inspectedValue}". Expected format: 'YYYY-MM-DD'`,
    },
  );
};
